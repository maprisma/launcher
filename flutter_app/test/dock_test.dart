// The dock's drawing and behaviour with a fake core and a recorded runner
// channel: no layer shell, no Hyprland, nothing started.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/dock_app.dart';
import 'package:maprisma_launcher/dock_geometry.dart';
import 'package:maprisma_launcher/settings_page.dart';

Map<String, dynamic> dockState({
  String edge = 'bottom',
  String bar = 'top',
  Map<String, dynamic> settings = const {},
}) => {
  'settings': {
    'dock_enabled': true,
    'dock_position': edge,
    'dock_align': 'center',
    'dock_height': 48,
    'dock_icon_size': 32,
    'dock_spacing': 6,
    'dock_magnify': 100,
    'dock_bounce': false,
    'dock_indicator_shown': true,
    'dock_indicator': 'line',
    'dock_indicator_color': 'theme',
    'dock_autohide': false,
    'dock_full_width': false,
    'dock_rounded': false,
    'dock_transparent': false,
    'dock_pinned': ['firefox'],
    ...settings,
  },
  'bar': bar,
  'edge': edge,
  'sizes': {'band': 48, 'item': 46, 'room': 48, 'grow': 0},
  'available': true,
  'look': {
    'colors': {'background': '#1e1e2e', 'foreground': '#cdd6f4', 'accent': '#89b4fa'},
    'rounding': 8,
  },
  'indicator_color': '#89b4fa',
  'corners': 'windows',
  'watch': const [],
};

final items = [
  {
    'key': '/apps/firefox.desktop',
    'desktop_id': 'firefox',
    'name': 'Firefox',
    'icon_file': null,
    'actions': [
      {'id': 'new-window', 'name': 'New Window'},
    ],
    'pinned': true,
    'windows': ['0x1a', '0x2b'],
    'new_window_action': true,
  },
  {
    'key': '/apps/files.desktop',
    'desktop_id': 'files',
    'name': 'Files',
    'icon_file': null,
    'actions': [],
    'pinned': false,
    'windows': ['0x3c'],
    'new_window_action': false,
  },
];

final class FakeCore {
  FakeCore(this.state, [List<Map<String, dynamic>>? shown]) : shown = shown ?? items;
  Map<String, dynamic> state;
  List<Map<String, dynamic>> shown;
  final calls = <(String, Map<String, dynamic>)>[];
  final surface = <(String, Object?)>[];
  void Function(int thickness)? onLayout;

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    switch (method) {
      case 'dock.items':
        return {'items': shown, 'active': '0x1a'};
      case 'dock.state':
        return state;
      case 'dock.set':
        state = {
          ...state,
          'settings': {...state['settings'] as Map, params['key']: params['value']},
        };
        return state;
      case 'packages.managers':
        return {'managers': []};
      default:
        return {'ok': true};
    }
  }

  /// The runner: a layout resizes the surface (the test view).
  Future<void> record(String method, [Object? args]) async {
    surface.add((method, args));
    if (method == 'layout') onLayout?.call((args as Map)['thickness'] as int);
  }
  Iterable<String> get routes => calls.map((c) => c.$1);
  Map? lastLayout() => surface.lastWhere((s) => s.$1 == 'layout').$2 as Map?;
  Object? lastInput() => surface.lastWhere((s) => s.$1 == 'input').$2;
}

Future<FakeCore> pumpDock(WidgetTester tester, FakeCore core, {Size size = const Size(1280, 88)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  core.onLayout = (thickness) => tester.view.physicalSize = Size(size.width, thickness.toDouble());
  await tester.pumpWidget(DockApp(core: core.call, state: core.state, surface: core.record));
  await tester.pump();
  await tester.pump();
  return core;
}

Future<void> rightClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
  await tester.pump(); // The menu opens: the surface grows …
  await tester.pump(); // … and the dock is drawn on it.
}

void main() {
  group('geometry', () {
    final slots = dockSlots([]);
    test('compact at the bottom: centred band, gap, exclusive zone, input', () {
      final g = DockGeometry(edge: 'bottom', settings: dockState()['settings'] as Map, sizes: dockState()['sizes'] as Map);
      expect(slots.map((s) => s.kind), [SlotKind.manager, SlotKind.separator, SlotKind.placeholder]);
      expect(g.contentLength(slots), 40 + 9 + 40 + 2 * 6);
      expect(g.thickness(), 6 + 48 + 34);
      expect(g.thickness(menu: true), 6 + 48 + 380);
      expect(g.stripRect(const Size(1000, 88)), const Rect.fromLTWH(0, 86, 1000, 2));
      expect(g.exclusive, 54);
      const size = Size(1000, 88);
      expect(g.bandRect(size, slots), Rect.fromLTWH((1000 - 117) / 2, 88 - 6 - 48, 117, 48));
      expect(g.inputRect(size, slots), Rect.fromLTWH((1000 - 117) / 2, 88 - 54, 117, 54));
      // The icons centred in the band: 1 px above its bottom edge.
      expect(g.slotRect(size, slots, 0), Rect.fromLTWH((1000 - 101) / 2, 88 - 7 - 46, 40, 46));
    });

    test('full length on the left, auto-hide, magnify', () {
      final g = DockGeometry(
        edge: 'left',
        settings: {...dockState()['settings'] as Map, 'dock_full_width': true, 'dock_autohide': true, 'dock_align': 'start'},
        sizes: {'band': 48, 'item': 70, 'room': 82, 'grow': 12},
      );
      const size = Size(302, 900);
      expect(g.gap, 0);
      expect(g.exclusive, 0);
      expect(g.thickness(), 82 + 220);
      expect(g.stripRect(const Size(302, 900)), const Rect.fromLTWH(0, 0, 2, 900));
      expect(g.bandRect(size, slots), const Rect.fromLTWH(0, 0, 48, 900));
      expect(g.inputRect(size, slots), const Rect.fromLTWH(0, 0, 82, 900));
      expect(g.slotRect(size, slots, 0).topLeft, const Offset(0, 8));
      final right = DockGeometry(edge: 'right', settings: dockState()['settings'] as Map, sizes: dockState()['sizes'] as Map);
      expect(right.bandRect(const Size(274, 900), slots).right, 274 - 6);
      expect(g.neighbours(dockSlots(items), 2), isEmpty); // separators on both sides
      const row = [DockSlot(SlotKind.manager), DockSlot(SlotKind.app, 'a'), DockSlot(SlotKind.app, 'b')];
      expect(g.neighbours(row, 1), {0, 2});
    });
  });

  testWidgets('pinned and running apps; the surface is sized; a click activates', (tester) async {
    final core = await pumpDock(tester, FakeCore(dockState()));
    expect(core.lastLayout(), {'edge': 'bottom', 'thickness': 88, 'exclusive': 54});
    // manager, separator, Firefox (pinned), separator, Files: 3 × 40 + 2 × 9 + 4 × 6 spacing, + 16 for the band.
    const content = 3 * 40 + 2 * 9 + 4 * 6;
    expect(core.lastInput(), [
      [((1280 - content - 16) / 2).floor(), 88 - 54, ((1280 + content + 16) / 2).ceil() - ((1280 - content - 16) / 2).floor(), 54],
    ]);
    expect(find.byKey(const ValueKey('dock-app:firefox')), findsOneWidget);
    expect(find.byKey(const ValueKey('dock-app:files')), findsOneWidget);
    expect(find.byKey(const ValueKey('dock-placeholder')), findsNothing);
    // Firefox has the focused window: its mark is the long one.
    expect(find.byKey(const ValueKey('dock-mark-active')), findsOneWidget);
    expect(find.byKey(const ValueKey('dock-mark')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dock-app:firefox')));
    await tester.pump();
    expect(core.calls.where((c) => c.$1 == 'dock.activate').single.$2, {'key': '/apps/firefox.desktop'});
    await tester.tap(find.byKey(const ValueKey('dock-manager')));
    await tester.pump();
    expect(core.routes, contains('dock.open_manager'));
    await tester.tap(find.byKey(const ValueKey('dock-app:files')), kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await tester.pump();
    expect(core.calls.where((c) => c.$1 == 'apps.launch').single.$2, {'key': '/apps/files.desktop'});
  });

  testWidgets('right-click: an app menu (no second New window for browsers), Unpin', (tester) async {
    final core = await pumpDock(tester, FakeCore(dockState()));
    await rightClick(tester, find.byKey(const ValueKey('dock-app:firefox')));
    expect(find.byKey(const ValueKey('dock-menu')), findsOneWidget);
    // The surface grows for the menu and takes the whole input while it is open.
    expect(core.lastLayout(), {'edge': 'bottom', 'thickness': 6 + 48 + 380, 'exclusive': 54});
    expect(core.lastInput(), isNull);
    expect(find.text('New window'), findsNothing);
    expect(find.text('New Window'), findsOneWidget);
    expect(find.text('Close all windows'), findsOneWidget);
    await tester.tap(find.text('Unpin from dock'));
    await tester.pump();
    expect(core.calls.where((c) => c.$1 == 'dock.pin').single.$2, {'key': '/apps/firefox.desktop', 'pinned': false});
    expect(find.byKey(const ValueKey('dock-menu')), findsNothing);

    await rightClick(tester, find.byKey(const ValueKey('dock-app:files')));
    expect(find.text('New window'), findsOneWidget);
    expect(find.text('Pin to dock'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(core.routes, contains('dock.close'));
  });

  testWidgets("the dock's own menu: every edge but the bar's, auto-hide", (tester) async {
    final core = await pumpDock(tester, FakeCore(dockState(bar: 'top')));
    await rightClick(tester, find.byKey(const ValueKey('dock-manager')));
    expect(find.text('Top'), findsNothing);
    expect(find.text('Bottom'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Auto-hide'), findsOneWidget);
    await tester.tap(find.text('Left'));
    await tester.pump();
    expect(core.calls.where((c) => c.$1 == 'dock.set').single.$2, {'key': 'dock_position', 'value': 'left'});
  });

  testWidgets('auto-hide: only a strip takes the pointer until it comes; hidden again after it left', (tester) async {
    final core = await pumpDock(tester, FakeCore(dockState(settings: {'dock_autohide': true})));
    expect(core.lastLayout(), {'edge': 'bottom', 'thickness': 88, 'exclusive': 0});
    expect(core.lastInput(), [
      [0, 86, 1280, 2],
    ]);
    expect(find.byKey(const ValueKey('dock-manager')), findsNothing);
    expect(find.byKey(const ValueKey('dock-strip')), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(640, 87));
    await mouse.moveTo(const Offset(640, 87)); // The 2 px strip on the screen edge.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('dock-manager')), findsOneWidget);
    expect((core.lastInput() as List).single, [((1280 - 162 - 16) / 2).floor(), 34, 178, 54]);
    await mouse.moveTo(const Offset(-50, -50));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.byKey(const ValueKey('dock-manager')), findsNothing);
    expect(core.lastInput(), [
      [0, 86, 1280, 2],
    ]);
  });

  testWidgets('nothing pinned: the placeholder; switched off: the dock quits', (tester) async {
    final core = await pumpDock(tester, FakeCore(dockState(), [items[1]]));
    expect(find.byKey(const ValueKey('dock-placeholder')), findsOneWidget);
    final view = tester.state<DockViewState>(find.byType(DockView));
    core.state = {
      ...core.state,
      'settings': {...core.state['settings'] as Map, 'dock_enabled': false},
    };
    await view.reloadState();
    await tester.pump();
    expect(core.surface.last, ('quit', 0));
  });

  testWidgets('Settings › Dock: switched on starts the dock; without gtk-layer-shell it says so', (tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = FakeCore(dockState(settings: {'dock_enabled': false}));
    await tester.pumpWidget(MaterialApp(home: SettingsPage(core: core.call, settings: const {}, onChanged: (_) {})));
    await tester.pumpAndSettle();
    expect(find.text('Dock'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dock_enabled')));
    await tester.pumpAndSettle();
    expect(core.calls.where((c) => c.$1 == 'dock.set').single.$2, {'key': 'dock_enabled', 'value': true});
    expect(core.routes, contains('dock.start'));

    final missing = FakeCore({...dockState(), 'available': false, 'reason': 'no_layer_shell'});
    await tester.pumpWidget(MaterialApp(home: SettingsPage(key: UniqueKey(), core: missing.call, settings: const {}, onChanged: (_) {})));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dock-unavailable')), findsOneWidget);
    expect(find.textContaining('gtk-layer-shell'), findsWidgets);
    expect(find.byKey(const ValueKey('dock_enabled')), findsNothing);
  });
}
