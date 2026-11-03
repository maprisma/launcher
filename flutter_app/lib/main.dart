import 'dart:async';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'apps_page.dart';
import 'backend.dart';
import 'core_call.dart';
import 'dock_app.dart';
import 'window_shots.dart';
import 'i18n.dart';

export 'apps_page.dart' show AppView, WideLayout;
export 'core_call.dart';
import 'theme.dart';

/// The runner's channel: "shown" (the window came back), "titlebar"
/// (dark or light), "hide".
const windowChannel = MethodChannel('maprisma-launcher/window');

/// Counts the times the window was shown again (--toggle, a second start).
final shownAgain = ValueNotifier<int>(0);

/// Whether the window has the focus (the runner's focus/blur).
final windowFocused = ValueNotifier<bool>(true);

/// While a dialog of another window runs (the folder chooser), the popup
/// loses the focus on purpose and must stay open (Maprisma's PopupGuard).
abstract final class PopupGuard {
  static int _depth = 0;
  static bool get busy => _depth > 0;
  static Future<T> around<T>(Future<T> Function() open) async {
    _depth++;
    try {
      return await open();
    } finally {
      _depth--;
    }
  }
}

Future<void> main(List<String> args) async {
  // `maprisma-launcher --dock`: the dock, a process of its own (dock_app.dart).
  if (args.contains('--dock')) return runDock();
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  final look = await backend.call('desktop.look').catchError((_) => <String, dynamic>{});
  final settings = await backend.call('settings.get').catchError((_) => <String, dynamic>{});
  await I18n.use(settings['language'] as String? ?? 'auto');
  // Omarchy: the dock comes up with the app when it is switched on (a running
  // one only re-reads its settings); the bar widget starts it with the shell.
  if (look['desktop'] == 'omarchy') backend.call('dock.start').ignore();
  windowChannel.setMethodCallHandler((call) async {
    if (call.method == 'shown') shownAgain.value++;
    if (call.method == 'focus') windowFocused.value = true;
    if (call.method == 'blur') windowFocused.value = false;
  });
  runApp(MaprismaLauncherApp(core: backend.call, look: look, settings: settings));
}

class MaprismaLauncherApp extends StatefulWidget {
  const MaprismaLauncherApp({super.key, required this.core, required this.look, this.settings = const {}});
  final CoreCall core;
  final Map<String, dynamic> look;
  final Map<String, dynamic> settings;
  @override
  State<MaprismaLauncherApp> createState() => _MaprismaLauncherState();
}

class _MaprismaLauncherState extends State<MaprismaLauncherApp> with WidgetsBindingObserver {
  late Map<String, dynamic> look = widget.look;
  late String cornersSetting = widget.settings['corners'] as String? ?? 'windows';
  late Map<String, dynamic> settings = widget.settings;

  /// Popup mode (Settings › Window): on Omarchy by default the window floats
  /// centred at the saved size without a title bar, as the old App Manager's
  /// card, and goes away with Esc or a click elsewhere.
  bool get popup {
    final mode = settings['window_mode'] as String? ?? 'auto';
    return mode == 'popup' || (mode == 'auto' && look['desktop'] == 'omarchy');
  }

  Timer? _blurHide;

  void _onFocus() {
    _blurHide?.cancel();
    if (windowFocused.value || !popup || PopupGuard.busy) return;
    // A moment's grace for focus that comes straight back.
    _blurHide = Timer(const Duration(milliseconds: 250), () {
      if (!windowFocused.value && !PopupGuard.busy) windowChannel.invokeMethod('hide').ignore();
    });
  }

  Future<void> _placePopup() async {
    if (!popup) return;
    windowChannel.invokeMethod('decorated', false).ignore();
    final size = settings['size'];
    final width = size is List && size.length == 2 ? size[0] as int : 1100;
    final height = size is List && size.length == 2 ? size[1] as int : 760;
    // Just shown: Hyprland may not list the window for a moment.
    for (var i = 0; i < 10; i++) {
      try {
        final done = await widget.core('window.popup', {'width': width, 'height': height});
        if (done['placed'] == true || done['reason'] != 'no window yet') return;
      } on Object {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// F12: a picture of this window and a note (window_shots.dart).
  final _windowShots = WindowShots.fromEnvironment(Platform.environment);
  final _shotArea = GlobalKey();
  final _navigator = GlobalKey<NavigatorState>();
  bool _shooting = false;

  bool _shotKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f12) return false;
    if (settings['screenshot_key'] == false) return false;
    unawaited(_takeShot());
    return true;
  }

  Future<void> _takeShot() async {
    final context = _navigator.currentContext;
    final area = _shotArea.currentContext?.findRenderObject();
    if (context == null || _shooting || area is! RenderRepaintBoundary) return;
    _shooting = true;
    try {
      final time = DateTime.now();
      final image = await area.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final path = await _windowShots.saveTo(
        settings['screenshot_folder'] as String?,
        data.buffer.asUint8List(),
        time,
      );
      if (!context.mounted) return;
      final note = await showDialog<String>(context: context, builder: (_) => ShotNote(path));
      await _windowShots.note(path, note ?? '');
    } catch (_) {
      // A picture must never disturb the app.
    } finally {
      _shooting = false;
    }
  }

  /// Settings › Corners and Language take effect at once.
  void _onSettings(Map<String, dynamic> settings) {
    final wasPopup = popup;
    setState(() {
      this.settings = settings;
      cornersSetting = settings['corners'] as String? ?? 'windows';
    });
    I18n.use(settings['language'] as String? ?? 'auto');
    // Settings › Window switched: the title bar comes back, or the popup floats.
    if (wasPopup != popup) {
      if (popup) {
        _placePopup();
      } else {
        windowChannel.invokeMethod('decorated', true).ignore();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    shownAgain.addListener(_reloadLook);
    shownAgain.addListener(_placePopup);
    windowFocused.addListener(_onFocus);
    HardwareKeyboard.instance.addHandler(_shotKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _placePopup());
    _syncTitlebar();
  }

  @override
  void dispose() {
    shownAgain.removeListener(_reloadLook);
    shownAgain.removeListener(_placePopup);
    windowFocused.removeListener(_onFocus);
    HardwareKeyboard.instance.removeHandler(_shotKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _reloadLook();

  /// A theme switch while hidden shows when the window comes back.
  Future<void> _reloadLook() async {
    try {
      final fresh = await widget.core('desktop.look');
      if (mounted) setState(() => look = fresh);
      _syncTitlebar();
    } on Object {
      // The old look stays.
    }
  }

  void _syncTitlebar() {
    final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final dark = appTheme(platform, look['colors'] as Map? ?? {}, 12).brightness == Brightness.dark;
    windowChannel.invokeMethod('titlebar', dark).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius(cornersSetting, look['rounding'] as int?);
    return ValueListenableBuilder(
      valueListenable: I18n.changed,
      builder: (context, _, _) => MaterialApp(
        navigatorKey: _navigator,
        // The picture F12 takes: the whole window, dialogs included.
        builder: (context, child) => RepaintBoundary(key: _shotArea, child: child),
        title: 'Maprisma Launcher',
        debugShowCheckedModeBanner: false,
        theme: appTheme(MediaQuery.platformBrightnessOf(context), look['colors'] as Map? ?? {}, radius),
        home: AppsPage(
          core: widget.core,
          desktop: '${look['desktop'] ?? ''}',
          shownAgain: shownAgain,
          onHide: () => windowChannel.invokeMethod('hide').ignore(),
          onSettings: _onSettings,
          windowRounding: look['rounding'] as int?,
        ),
      ),
    );
  }
}
