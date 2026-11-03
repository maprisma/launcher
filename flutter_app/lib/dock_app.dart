/// The dock (`maprisma-launcher --dock`, Omarchy only): pinned and running
/// apps along a screen edge, as the Omarchy App Manager's dock.py. The runner
/// makes the window a gtk-layer-shell surface (my_application.cc); this side
/// draws the dock and tells the runner its size, exclusive zone and input
/// region over the "maprisma-launcher/dock" channel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart' show HyprEvents, dockEvent;

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'dock_geometry.dart';
import 'i18n.dart';
import 'theme.dart';

const dockChannel = MethodChannel('maprisma-launcher/dock');

/// The runner's side: "layout", "input", "quit".
typedef SurfaceCall = Future<void> Function(String method, [Object? args]);

Future<void> _channel(String method, [Object? args]) async {
  try {
    await dockChannel.invokeMethod<void>(method, args);
  } on MissingPluginException {
    // Not under the dock's runner (a test).
  }
}

const pollInterval = Duration(seconds: 4); // A fallback: Hyprland's events update the dock at once.
const hideDelay = Duration(milliseconds: 700);
const _menuWidth = 220.0;

/// The dock process's Dart side: refuses unless the dock is on and possible here.
Future<void> runDock() async {
  WidgetsFlutterBinding.ensureInitialized();
  Future<void> quit(int code) async {
    try {
      await dockChannel.invokeMethod<void>('quit', code);
    } on Object {
      exit(code);
    }
  }

  final Backend backend;
  Map<String, dynamic> state;
  try {
    backend = await Backend.start();
    state = await backend.call('dock.state');
  } on Object catch (e) {
    stderr.writeln('maprisma-launcher --dock: $e');
    return quit(1);
  }
  if (state['available'] != true) {
    stderr.writeln('maprisma-launcher --dock: not available here (${state['reason']})');
    return quit(5);
  }
  if ((state['settings'] as Map)['dock_enabled'] != true) return quit(0);
  final settings = await backend.call('settings.get').catchError((_) => <String, dynamic>{});
  await I18n.use(settings['language'] as String? ?? 'auto');
  dockChannel.setMethodCallHandler((call) async {
    if (call.method == 'reload') dockReload.value++;
  });
  runApp(DockApp(core: backend.call, state: state, eventsPath: HyprEvents.socketPath(Platform.environment)));
}

/// Counts "started again" (a second `--dock`): the dock re-reads its settings.
final dockReload = ValueNotifier<int>(0);

class DockApp extends StatelessWidget {
  const DockApp({super.key, required this.core, required this.state, this.eventsPath, this.surface = _channel});
  final CoreCall core;
  final Map<String, dynamic> state;
  final String? eventsPath;
  final SurfaceCall surface;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    color: Colors.transparent,
    theme: appTheme(Brightness.dark, (state['look'] as Map?)?['colors'] as Map? ?? const {}, 12),
    home: DockView(core: core, state: state, eventsPath: eventsPath, surface: surface),
  );
}

/// A menu on the dock: its entries and what it points at.
final class DockMenu {
  DockMenu(this.title, this.along, this.across, this.entries);
  final String title;

  /// What it points at: its middle along the edge and its far side's
  /// distance from the edge (the surface grows while a menu is open).
  final double along, across;
  final List<DockMenuEntry> entries;
}

final class DockMenuEntry {
  DockMenuEntry(this.label, this.onTap, {this.destructive = false, this.current = false, this.toggle}) : line = false;
  DockMenuEntry.separator() : label = '', onTap = null, destructive = false, current = false, toggle = null, line = true;
  final String label;
  final VoidCallback? onTap;
  final bool destructive, current, line;
  final bool? toggle;
}

class DockView extends StatefulWidget {
  const DockView({super.key, required this.core, required this.state, this.eventsPath, required this.surface});
  final CoreCall core;
  final Map<String, dynamic> state;
  final String? eventsPath;
  final SurfaceCall surface;
  @override
  State<DockView> createState() => DockViewState();
}

class DockViewState extends State<DockView> with TickerProviderStateMixin {
  late Map<String, dynamic> state = widget.state;
  List<Map> items = [];
  String? active;
  final urgent = <String>{};
  bool revealed = true;
  int revealCount = 0;
  bool pointerInside = false;
  int? hovered;
  DockMenu? menu;
  String? dragging;
  (String, bool)? dropAt;
  Size _size = Size.zero;
  String? _signature;
  String? _lastLayout, _lastInput;
  Timer? _hideTimer, _menuClose, _poll, _periodic, _watch, _settle, _configSettle;
  StreamSubscription<String>? _events;
  final _stopEvents = Completer<void>();
  bool _refreshing = false, _again = false, _stale = false;
  final _mtimes = <String, int>{};
  late final AnimationController bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  Map get settings => state['settings'] as Map;
  String get edge => '${state['edge'] ?? 'bottom'}';
  bool get autohide => settings['dock_autohide'] == true;
  bool get shown => revealed || !autohide;
  DockGeometry get geometry => DockGeometry(edge: edge, settings: settings, sizes: state['sizes'] as Map? ?? const {});
  Map get colors => (state['look'] as Map?)?['colors'] as Map? ?? const {};

  Color _color(String key, Color fallback) => hexColor(colors, key) ?? fallback;
  Color get background => _color('background', const Color(0xff1e1e2e));
  Color get foreground => _color('foreground', const Color(0xffcdd6f4));
  Color get accent => _color('accent', const Color(0xff89b4fa));

  /// Settings › Corners and the windows' rounding; never square on the dock.
  double get radius {
    final r = cornerRadius('${state['corners'] ?? 'windows'}', (state['look'] as Map?)?['rounding'] as int?);
    return r > 0 ? r : 12;
  }

  @override
  void initState() {
    super.initState();
    revealed = !autohide;
    dockReload.addListener(reloadState);
    refresh(rescan: true);
    _poll = Timer.periodic(pollInterval, (_) => refresh());
    // Newly installed apps and theme changes.
    _periodic = Timer.periodic(const Duration(seconds: 60), (_) {
      reloadState();
      refresh(rescan: true);
    });
    _noteMtimes();
    _watch = Timer.periodic(const Duration(seconds: 1), (_) => _checkFiles());
    final path = widget.eventsPath;
    if (path != null) {
      _events = HyprEvents(path).lines(stop: _stopEvents.future).listen((line) {
        if (dockEvent(line, urgent)) {
          _settle ??= Timer(const Duration(milliseconds: 120), () {
            _settle = null;
            refresh();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    dockReload.removeListener(reloadState);
    for (final t in [_hideTimer, _menuClose, _poll, _periodic, _watch, _settle, _configSettle]) {
      t?.cancel();
    }
    if (!_stopEvents.isCompleted) _stopEvents.complete();
    _events?.cancel();
    bounce.dispose();
    super.dispose();
  }

  // --- settings and contents -------------------------------------------------------

  List<String> get _watched => [for (final f in state['watch'] as List? ?? const []) '$f'];

  void _noteMtimes() {
    for (final f in _watched) {
      _mtimes[f] = _mtime(f);
    }
  }

  static int _mtime(String path) {
    final stat = FileStat.statSync(path);
    return stat.type == FileSystemEntityType.notFound ? -1 : stat.modified.microsecondsSinceEpoch;
  }

  /// settings.json, icons.json and the bar's shell.json: changes apply at once.
  void _checkFiles() {
    var changed = false;
    for (final f in _watched) {
      final now = _mtime(f);
      if (_mtimes[f] != now) {
        _mtimes[f] = now;
        changed = true;
      }
    }
    if (!changed) return;
    _configSettle?.cancel();
    _configSettle = Timer(const Duration(milliseconds: 250), () {
      reloadState();
      refresh(rescan: true);
    });
  }

  Future<void> reloadState() async {
    Map<String, dynamic> fresh;
    try {
      fresh = await widget.core('dock.state');
    } on Object {
      return;
    }
    _apply(fresh);
  }

  void _apply(Map<String, dynamic> fresh) {
    if (!mounted) return;
    if (fresh['available'] != true || (fresh['settings'] as Map?)?['dock_enabled'] != true) {
      widget.surface('quit', 0); // Switched off: the dock ends.
      return;
    }
    final wasAutohide = autohide;
    setState(() {
      state = fresh;
      if (!autohide) {
        revealed = true;
      } else if (!wasAutohide && !pointerInside && menu == null) {
        revealed = false;
      }
    });
    _noteMtimes();
  }

  /// Hyprland's windows and the apps (rescan: the app list read again).
  Future<void> refresh({bool rescan = false}) async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      final r = await widget.core('dock.items', {'rescan': rescan});
      final next = [for (final i in r['items'] as List) Map<String, dynamic>.from(i as Map)];
      final signature = jsonEncode([next, r['active'], urgent.toList()..sort()]);
      // Never during a drag or with a menu open (a rebuild would end them).
      if (dragging != null || menu != null) {
        _stale = true;
      } else if (signature != _signature && mounted) {
        _signature = signature;
        setState(() {
          items = next;
          active = r['active'] as String?;
        });
      }
    } on Object {
      // The old contents stay.
    } finally {
      _refreshing = false;
      if (_again) {
        _again = false;
        refresh();
      }
    }
  }

  Future<void> _call(String route, [Map<String, dynamic> params = const {}]) async {
    try {
      final r = await widget.core(route, params);
      if (r['settings'] is Map) _apply(r);
    } on Object {
      // A dock click that did not work changes nothing.
    }
    refresh();
  }

  // --- auto-hide ---------------------------------------------------------------------

  void _enter() {
    pointerInside = true;
    _hideTimer?.cancel();
    _menuClose?.cancel();
    if (!revealed) {
      setState(() {
        revealed = true;
        revealCount++;
      });
    }
  }

  void _exit() {
    pointerInside = false;
    if (hovered != null) setState(() => hovered = null);
    if (menu != null) {
      // Gone elsewhere: the menu closes (the surface lets nothing else through while it is open).
      _menuClose = Timer(const Duration(milliseconds: 600), closeMenu);
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    if (!autohide) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(hideDelay, _hideWhenIdle);
  }

  void _hideWhenIdle() {
    if (!mounted) return;
    if (menu != null || dragging != null || pointerInside) {
      _scheduleHide();
      return;
    }
    if (autohide && revealed) setState(() => revealed = false);
  }

  // --- the surface: size, exclusive zone, input region ---------------------------------------

  void _syncSurface(List<DockSlot> slots) {
    if (!mounted) return;
    final g = geometry;
    final layout = {'edge': edge, 'thickness': g.thickness(menu: menu != null), 'exclusive': g.exclusive};
    final key = jsonEncode(layout);
    if (key != _lastLayout) {
      _lastLayout = key;
      widget.surface('layout', layout);
    }
    Object? input;
    if (menu == null && dragging == null && _size.width > 0 && _size.height > 0) {
      // Shown: the dock; hidden: the strip on the screen edge that brings it back.
      final r = shown ? g.inputRect(_size, slots) : g.stripRect(_size);
      input = [
        [r.left.floor(), r.top.floor(), (r.right.ceil() - r.left.floor()), (r.bottom.ceil() - r.top.floor())],
      ];
    }
    final inputKey = jsonEncode(input);
    if (inputKey != _lastInput) {
      _lastInput = inputKey;
      widget.surface('input', input);
    }
  }

  // --- menus -----------------------------------------------------------------------------

  /// A rectangle on the surface as (along, across from the edge).
  (double, double) _anchor(Rect r) => switch (edge) {
    'top' => (r.center.dx, r.bottom),
    'left' => (r.center.dy, r.right),
    'right' => (r.center.dy, _size.width - r.left),
    _ => (r.center.dx, _size.height - r.top),
  };

  void openMenu(DockMenu next) {
    _menuClose?.cancel();
    setState(() {
      menu = next;
      hovered = null;
    });
  }

  void closeMenu() {
    if (!mounted || menu == null) return;
    setState(() => menu = null);
    if (_stale) {
      _stale = false;
      _signature = null;
      refresh();
    }
    _scheduleHide();
  }

  void _run(VoidCallback action) {
    closeMenu();
    action();
  }

  /// Right-click on the dock: its edge (all but the bar's) and auto-hide.
  void settingsMenu(Rect anchor) {
    final bar = state['bar'];
    final names = {'bottom': tr('Bottom'), 'top': tr('Top'), 'left': tr('Left'), 'right': tr('Right')};
    final (along, across) = _anchor(anchor);
    openMenu(DockMenu(tr('Dock'), along, across, [
      DockMenuEntry.separator(),
      for (final position in const ['bottom', 'top', 'left', 'right'])
        if (position != bar)
          DockMenuEntry(names[position]!, () => _run(() => _call('dock.set', {'key': 'dock_position', 'value': position})),
              current: position == edge),
      DockMenuEntry.separator(),
      DockMenuEntry(tr('Auto-hide'), () => _run(() => _call('dock.set', {'key': 'dock_autohide', 'value': !autohide})),
          toggle: autohide),
    ]));
  }

  void appMenu(Map item, Rect anchor) {
    final key = item['key'];
    final windows = item['windows'] as List? ?? const [];
    final pinned = item['pinned'] == true;
    final (along, across) = _anchor(anchor);
    openMenu(DockMenu('${item['name']}', along, across, [
      // Browsers bring their own "New Window" action: no second one then.
      if (!(windows.isNotEmpty && item['new_window_action'] == true))
        DockMenuEntry(windows.isNotEmpty ? tr('New window') : tr('Open'), () => _run(() => _call('apps.launch', {'key': key}))),
      for (final a in (item['actions'] as List? ?? const []).take(6))
        DockMenuEntry('${(a as Map)['name']}', () => _run(() => _call('apps.action', {'key': key, 'action': a['id']}))),
      if (pinned)
        DockMenuEntry(tr('Unpin from dock'), () => _run(() => _call('dock.pin', {'key': key, 'pinned': false})))
      else
        DockMenuEntry(tr('Pin to dock'), () => _run(() => _call('dock.pin', {'key': key, 'pinned': true}))),
      if (windows.isNotEmpty)
        DockMenuEntry(windows.length == 1 ? tr('Close') : tr('Close all windows'),
            () => _run(() => _call('dock.close', {'key': key})), destructive: true),
    ]));
  }

  // --- drag and drop (pinned apps only) ---------------------------------------------------

  void _endDrag() {
    setState(() {
      dragging = null;
      dropAt = null;
    });
    _signature = null;
    refresh(); // Rebuilt only now: a rebuild during the drag ends it.
    _scheduleHide();
  }

  // --- drawing --------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final slots = dockSlots(items);
    final byKey = {for (final i in items) '${i['key']}': i};
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSurface(slots));
    final wantBounce = settings['dock_bounce'] == true &&
        items.any((i) => (i['windows'] as List? ?? const []).any(urgent.contains));
    if (wantBounce && !bounce.isAnimating) {
      bounce.repeat();
    } else if (!wantBounce && bounce.isAnimating) {
      bounce.stop();
    }
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size != _size) {
            _size = size;
            WidgetsBinding.instance.addPostFrameCallback((_) => _syncSurface(slots));
          }
          return MouseRegion(
            opaque: false,
            onEnter: (_) => _enter(),
            onExit: (_) => _exit(),
            // Hidden: the strip, all but invisible. (A frame with nothing in it at all
            // left the last dock on screen under GTK3.)
            child: shown
                ? _dock(size, slots, byKey)
                : Stack(
                    children: [
                      Positioned.fromRect(
                        rect: geometry.stripRect(size),
                        child: const ColoredBox(key: ValueKey('dock-strip'), color: Color(0x01000000)),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _dock(Size size, List<DockSlot> slots, Map<String, Map> byKey) {
    final g = geometry;
    final markerAt = dropAt == null ? -1 : slots.indexWhere((s) => byKey[s.key]?['desktop_id'] == dropAt!.$1);
    final parts = <Widget>[
      Positioned.fromRect(rect: g.bandRect(size, slots), child: _band(g, size)),
      for (var i = 0; i < slots.length; i++)
        Positioned.fromRect(rect: g.slotRect(size, slots, i), child: _slot(g, size, slots, i, byKey)),
      if (markerAt >= 0)
        Positioned.fromRect(
          rect: g.markerRect(size, slots, markerAt, after: dropAt!.$2),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [BoxShadow(color: accent.withValues(alpha: .8), blurRadius: 6)],
              ),
            ),
          ),
        ),
    ];
    // Shown again: the dock slides in from its edge.
    final away = switch (edge) {
      'top' => const Offset(0, -1),
      'left' => const Offset(-1, 0),
      'right' => const Offset(1, 0),
      _ => const Offset(0, 1),
    };
    final extent = (g.gap + g.room).toDouble();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            key: ValueKey(revealCount),
            tween: Tween(begin: autohide ? 1 : 0, end: 0),
            duration: const Duration(milliseconds: 160),
            builder: (context, t, child) => Transform.translate(offset: away * extent * t, child: child),
            child: Stack(clipBehavior: Clip.none, children: parts),
          ),
        ),
        if (menu != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: closeMenu,
              onSecondaryTap: closeMenu,
              child: const SizedBox.expand(),
            ),
          ),
        if (menu == null && dragging == null && hovered != null && hovered! < slots.length)
          _tip(g, size, slots, hovered!, byKey),
        if (menu != null) _menu(g, size, menu!),
      ],
    );
  }

  Widget _band(DockGeometry g, Size size) {
    final transparent = settings['dock_transparent'] == true;
    final rounded = settings['dock_rounded'] == true;
    final r = Radius.circular(radius + 4);
    final side = BorderSide(color: transparent ? Colors.transparent : foreground.withValues(alpha: .15));
    // Full length: no border on the screen edge and the ends; rounded only away from the edge.
    final border = !g.full
        ? Border.fromBorderSide(side)
        : switch (edge) {
            'top' => Border(bottom: side),
            'left' => Border(right: side),
            'right' => Border(left: side),
            _ => Border(top: side),
          };
    final corners = !rounded
        ? BorderRadius.zero
        : !g.full
        ? BorderRadius.all(r)
        : switch (edge) {
            'top' => BorderRadius.only(bottomLeft: r, bottomRight: r),
            'left' => BorderRadius.only(topRight: r, bottomRight: r),
            'right' => BorderRadius.only(topLeft: r, bottomLeft: r),
            _ => BorderRadius.only(topLeft: r, topRight: r),
          };
    return GestureDetector(
      key: const ValueKey('dock-band'),
      behavior: HitTestBehavior.opaque,
      // Double-click the background: transparent or not, as on the bar.
      onDoubleTap: () => _call('dock.set', {'key': 'dock_transparent', 'value': !transparent}),
      // (The dock fills its window: global positions are surface positions.)
      onSecondaryTapUp: (d) => settingsMenu(Rect.fromCenter(center: d.globalPosition, width: 1, height: 1)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: transparent ? Colors.transparent : background.withValues(alpha: .92),
          border: border,
          borderRadius: corners,
        ),
      ),
    );
  }

  Alignment get _edgeAlignment => switch (edge) {
    'top' => Alignment.topCenter,
    'left' => Alignment.centerLeft,
    'right' => Alignment.centerRight,
    _ => Alignment.bottomCenter,
  };

  Widget _slot(DockGeometry g, Size size, List<DockSlot> slots, int index, Map<String, Map> byKey) {
    final slot = slots[index];
    switch (slot.kind) {
      case SlotKind.separator:
        final line = Container(
          width: g.vertical ? null : 1,
          height: g.vertical ? 1 : null,
          margin: const EdgeInsets.all(4),
          color: foreground.withValues(alpha: .18),
        );
        return line;
      case SlotKind.placeholder:
        return MouseRegion(
          onEnter: (_) => setState(() => hovered = index),
          onExit: (_) => setState(() => hovered = null),
          child: Center(
            child: Container(
              key: const ValueKey('dock-placeholder'),
              width: g.icon.toDouble(),
              height: g.icon.toDouble(),
              decoration: BoxDecoration(
                border: Border.all(color: foreground.withValues(alpha: .45)),
                borderRadius: BorderRadius.circular(math.max(4, radius)),
              ),
              child: Icon(Icons.add, size: 18, color: foreground.withValues(alpha: .7)),
            ),
          ),
        );
      case SlotKind.manager:
        return _button(
          g,
          slots,
          index,
          key: const ValueKey('dock-manager'),
          icon: Icon(Icons.apps, size: math.max(16, g.icon - 12).toDouble(), color: foreground),
          onTap: () => _call('dock.open_manager'),
          onSecondary: (rect) => settingsMenu(rect),
          slotRect: g.slotRect(size, slots, index),
        );
      case SlotKind.app:
        final item = byKey[slot.key]!;
        final windows = (item['windows'] as List? ?? const []).cast<String>();
        final rect = g.slotRect(size, slots, index);
        Widget button = _button(
          g,
          slots,
          index,
          key: ValueKey('dock-app:${item['desktop_id']}'),
          icon: AppIcon(item['icon_file'] as String?, size: g.icon.toDouble()),
          mark: windows.isNotEmpty && settings['dock_indicator_shown'] != false
              ? _mark(g, windows.contains(active))
              : null,
          bouncing: settings['dock_bounce'] == true && windows.any(urgent.contains),
          onTap: () => _call('dock.activate', {'key': item['key']}),
          onMiddle: () => _call('apps.launch', {'key': item['key']}), // Always a new window.
          onSecondary: (_) => appMenu(item, rect),
          slotRect: rect,
        );
        if (item['pinned'] == true) button = _reorder(g, item, button);
        return button;
    }
  }

  Widget _mark(DockGeometry g, bool focused) {
    final color = Color(
      0xff000000 | (int.tryParse('${state['indicator_color'] ?? ''}'.replaceFirst('#', ''), radix: 16) ?? 0x888888),
    );
    final line = settings['dock_indicator'] == 'line';
    final long = math.max(12, (g.icon * .6).round()).toDouble();
    final short = math.max(6, (long / 2).round()).toDouble();
    double along, across;
    if (line) {
      along = focused ? long : short;
      across = 3;
    } else {
      along = focused ? 14 : 5;
      across = 5;
    }
    return Container(
      key: ValueKey(focused ? 'dock-mark-active' : 'dock-mark'),
      width: g.vertical ? across : along,
      height: g.vertical ? along : across,
      decoration: BoxDecoration(
        color: focused ? color : color.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(line ? 2 : 999),
        boxShadow: settings['dock_transparent'] == true
            ? [BoxShadow(color: Colors.black.withValues(alpha: .8), blurRadius: 2)]
            : null,
      ),
    );
  }

  /// An icon button: the icon (grows on hover, bounces on alerts) with room
  /// for the running mark on the screen-edge side.
  Widget _button(
    DockGeometry g,
    List<DockSlot> slots,
    int index, {
    required Key key,
    required Widget icon,
    Widget? mark,
    bool bouncing = false,
    required VoidCallback onTap,
    VoidCallback? onMiddle,
    required void Function(Rect) onSecondary,
    required Rect slotRect,
  }) {
    final magnify = (settings['dock_magnify'] as num? ?? 100) / 100;
    final grown = hovered == index && menu == null && dragging == null;
    final near = hovered != null && menu == null && g.neighbours(slots, hovered!).contains(index);
    final scale = magnify > 1 ? (grown ? magnify : (near ? 1 + (magnify - 1) / 2 : 1.0)) : 1.0;
    final pad = switch (edge) {
      'top' => const EdgeInsets.only(top: 6),
      'left' => const EdgeInsets.only(left: 6),
      'right' => const EdgeInsets.only(right: 6),
      _ => const EdgeInsets.only(bottom: 6),
    };
    Widget slot = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: Padding(padding: pad, child: Center(child: icon))),
        if (mark != null) Align(alignment: _edgeAlignment, child: mark),
      ],
    );
    slot = AnimatedScale(scale: scale, alignment: _edgeAlignment, duration: const Duration(milliseconds: 120), child: slot);
    if (bouncing) {
      final away = switch (edge) {
        'top' => const Offset(0, 1),
        'left' => const Offset(1, 0),
        'right' => const Offset(-1, 0),
        _ => const Offset(0, -1),
      };
      slot = AnimatedBuilder(
        animation: bounce,
        builder: (context, child) =>
            Transform.translate(offset: away * (dockBounceHeight * math.sin(math.pi * bounce.value)), child: child),
        child: slot,
      );
    }
    final hoverFill = magnify > 1 ? Colors.transparent : foreground.withValues(alpha: .10);
    return MouseRegion(
      key: key,
      onEnter: (_) => setState(() => hovered = index),
      onExit: (_) {
        if (hovered == index) setState(() => hovered = null);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onTertiaryTapUp: onMiddle == null ? null : (_) => onMiddle(),
        onSecondaryTapUp: (_) => onSecondary(slotRect),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: grown ? hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(math.max(4, radius)),
          ),
          child: slot,
        ),
      ),
    );
  }

  Widget _reorder(DockGeometry g, Map item, Widget button) {
    final id = '${item['desktop_id']}';
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => dragging != null && d.data != id,
      onMove: (d) {
        if (dragging == null || d.data == id) return;
        final local = d.offset; // The pointer, in surface positions.
        final rect = g.slotRect(_size, dockSlots(items), dockSlots(items).indexWhere((s) => s.key == '${item['key']}'));
        final after = g.vertical ? local.dy > rect.center.dy : local.dx > rect.center.dx;
        if (dropAt != (id, after)) setState(() => dropAt = (id, after));
      },
      onLeave: (_) {
        if (dropAt?.$1 == id) setState(() => dropAt = null);
      },
      onAcceptWithDetails: (d) {
        final after = dropAt?.$1 == id && dropAt!.$2;
        _call('dock.move', {'id': d.data, 'target': id, 'after': after});
      },
      builder: (context, _, _) => Draggable<String>(
        data: id,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: IgnorePointer(
          child: Opacity(
            opacity: .85,
            child: Transform.translate(
              offset: Offset(-g.icon / 2, -g.icon / 2),
              child: AppIcon(item['icon_file'] as String?, size: g.icon.toDouble()),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: .35, child: button),
        onDragStarted: () => setState(() {
          dragging = id;
          hovered = null;
        }),
        onDragEnd: (_) => _endDrag(),
        child: button,
      ),
    );
  }

  /// The hovered icon's name, beyond the dock (the surface's tip room).
  Widget _tip(DockGeometry g, Size size, List<DockSlot> slots, int index, Map<String, Map> byKey) {
    final slot = slots[index];
    final String text;
    switch (slot.kind) {
      case SlotKind.manager:
        text = 'Maprisma Launcher';
      case SlotKind.placeholder:
        text = tr("Pin apps with “Pin to dock” in Maprisma Launcher's menu");
      case SlotKind.app:
        final item = byKey[slot.key]!;
        final count = (item['windows'] as List? ?? const []).length;
        text = count < 2 ? '${item['name']}' : '${item['name']} ($count)';
      case SlotKind.separator:
        return const SizedBox.shrink();
    }
    final rect = g.slotRect(size, slots, index);
    final across = (g.gap + g.room + 2).toDouble();
    final Rect strip;
    final Alignment align;
    if (g.vertical) {
      final center = rect.center.dy;
      strip = g.place(size, (center - 16).clamp(0, math.max(0, size.height - 32)), across, 32, tipRoom(true) - 4);
      align = edge == 'left' ? Alignment.centerLeft : Alignment.centerRight;
    } else {
      final center = rect.center.dx;
      const width = 400.0;
      strip = g.place(size, (center - width / 2).clamp(0, math.max(0, size.width - width)), across, width,
          tipRoom(false) - 4);
      align = edge == 'top' ? Alignment.topCenter : Alignment.bottomCenter;
    }
    return Positioned.fromRect(
      rect: strip,
      child: IgnorePointer(
        child: Align(
          alignment: align,
          child: Container(
            key: const ValueKey('dock-tip'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xff282526),
              borderRadius: BorderRadius.circular(math.max(4, radius / 2)),
              border: Border.all(color: accent.withValues(alpha: .6)),
            ),
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ),
      ),
    );
  }

  Widget _menu(DockGeometry g, Size size, DockMenu m) {
    final r = math.max(4.0, radius);
    final body = Container(
      key: const ValueKey('dock-menu'),
      constraints: const BoxConstraints(minWidth: 170, maxWidth: _menuWidth),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: const Color(0xff282526),
        border: Border.all(color: accent),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
              child: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: .7))),
            ),
            for (final e in m.entries)
              if (e.line)
                Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                    color: Colors.white.withValues(alpha: .18))
              else
                InkWell(
                  onTap: e.onTap,
                  borderRadius: BorderRadius.circular(r),
                  hoverColor: accent.withValues(alpha: .35),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: e.current ? accent.withValues(alpha: .22) : null,
                      borderRadius: BorderRadius.circular(r),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            e.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: e.current ? FontWeight.w700 : FontWeight.w500,
                              color: e.destructive ? const Color(0xffff9999) : Colors.white,
                            ),
                          ),
                        ),
                        if (e.toggle != null)
                          IgnorePointer(
                            child: Transform.scale(
                              scale: .7,
                              child: Switch(value: e.toggle!, onChanged: (_) {}, activeTrackColor: accent),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
    // Away from the screen edge, kept on the surface.
    double start(double length, double total) => (m.along - length / 2).clamp(4, math.max(4, total - length - 4));
    final off = m.across + 6;
    return switch (edge) {
      'top' => Positioned(top: off, left: start(_menuWidth, size.width), child: body),
      'left' => Positioned(left: off, top: start(300, size.height), child: body),
      'right' => Positioned(right: off, top: start(300, size.height), child: body),
      _ => Positioned(bottom: off, left: start(_menuWidth, size.width), child: body),
    };
  }
}

/// How far an icon jumps when its app wants attention (dock_core.BOUNCE).
const dockBounceHeight = 14.0;
