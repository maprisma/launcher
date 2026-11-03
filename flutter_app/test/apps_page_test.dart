/// The apps page against the real core on a fixture home: views, folding,
/// moving an entry to a new group, hiding.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher/apps_page.dart';
import 'package:maprisma_launcher/i18n.dart';
import 'package:maprisma_launcher/install_page.dart';
import 'package:maprisma_launcher/terminal_page.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:maprisma_launcher/main.dart' show MaprismaLauncherApp;
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory home;
  late CoreService core;

  setUp(() {
    home = Directory.systemTemp.createTempSync('am-page-');
    final apps = p.join(home.path, 'data/applications');
    Directory(apps).createSync(recursive: true);
    for (final (id, name, cats) in [
      ('writer', 'Writer', 'Office;'),
      ('player', 'Player', 'AudioVideo;'),
      ('misc', 'Misc', ''),
    ]) {
      File(p.join(apps, '$id.desktop'))
          .writeAsStringSync('[Desktop Entry]\nType=Application\nName=$name\nExec=/bin/true\nCategories=$cats\n');
    }
    core = CoreService(
      environment: {
        'HOME': home.path,
        // No programs: the core starts no process (gsettings) in fake time.
        'PATH': '/nonexistent',
        'XDG_DATA_HOME': p.join(home.path, 'data'),
        'XDG_DATA_DIRS': p.join(home.path, 'none'),
        'XDG_CURRENT_DESKTOP': 'GNOME',
        'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
      },
    );
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final reply = jsonDecode(
      await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})),
    ) as Map;
    if (reply['error'] case final Map e) throw ServiceError('${e['code']}', e['message'] as String?);
    return Map<String, dynamic>.from(reply['result'] as Map);
  }

  /// Pump until the core's file work and the page's setState settle.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      // Animation time too: page transitions finish.
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('groups view: fold, new group with an entry, hide', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppsPage(key: key, core: call, desktop: 'generic'),
      ),
    );
    await settle(tester);
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('Office'), findsNothing); // the list view has no headings

    await key.currentState!.setView(AppView.groups);
    await settle(tester);
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget); // Misc is in it
    expect(find.text('Games'), findsOneWidget); // empty groups show while browsing

    await tester.tap(find.text('Office'));
    await settle(tester);
    expect(find.text('Writer'), findsNothing);
    expect(((await call('groups.get'))['collapsed'] as List), ['office']);
    await tester.tap(find.text('Office'));
    await settle(tester);
    expect(find.text('Writer'), findsOneWidget);

    // Move to group › New group…: the dialog, then the entry is in it.
    await tester.runAsync(() async {
      await call('apps.list');
      await call('groups.add', {'name': 'Mine', 'key': p.join(home.path, 'data/applications/misc.desktop')});
    });
    await key.currentState!.setView(AppView.list);
    await key.currentState!.setView(AppView.groups);
    await settle(tester);
    expect(find.text('Mine'), findsOneWidget);
    final sections = await tester.runAsync(
      () => call('apps.sections', {
        'view': 'groups',
        'keys': [p.join(home.path, 'data/applications/misc.desktop')],
      }),
    );
    expect(
      [
        for (final s in sections!['sections'] as List)
          if ((s['keys'] as List).isNotEmpty) s['id'],
      ],
      ['g1'],
    );

    // Filtering hides empty groups.
    await tester.enterText(find.byType(TextField), 'wri');
    await settle(tester);
    expect(find.text('Games'), findsNothing);
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('1 of 3 apps'), findsOneWidget);

    // Hide from list: gone until "Show hidden".
    await tester.runAsync(
      () => call('apps.hide', {'key': p.join(home.path, 'data/applications/writer.desktop'), 'hidden': true}),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    await settle(tester);
    expect(find.text('Writer'), findsNothing);
    expect(find.text('0 of 3 apps'), findsOneWidget);
    await tester.tap(find.byTooltip('Show hidden apps (1)'));
    await settle(tester);
    expect(find.text('Writer'), findsOneWidget);
  });

  testWidgets('drag and drop: onto a heading, beside an entry, groups, New group', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppsPage(key: key, core: call, desktop: 'generic'),
      ),
    );
    await settle(tester);
    await key.currentState!.setView(AppView.groups);
    await settle(tester);

    Future<void> drag(Finder from, Offset to) async {
      final start = tester.getCenter(from);
      final gesture = await tester.startGesture(start);
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(start, to, i / 10)!);
        await tester.pump();
      }
      await gesture.up();
      await settle(tester);
    }

    Future<List> section(String id) async {
      final result = await tester.runAsync(
        () => call('apps.sections', {
          'view': 'groups',
          'keys': [
            for (final a in ['misc', 'player', 'writer']) p.join(home.path, 'data/applications/$a.desktop'),
          ],
        }),
      );
      return [
        for (final s in result!['sections'] as List)
          if (s['id'] == id)
            for (final k in s['keys'] as List) p.basenameWithoutExtension(k as String),
      ];
    }

    // Misc (Other) onto the Office heading: into Office, at the end.
    await drag(find.text('Misc'), tester.getCenter(find.text('Office')));
    expect(await section('office'), ['writer', 'misc']);

    // Player onto the upper half of Writer: into Office, before Writer.
    final writer = tester.getRect(find.ancestor(of: find.text('Writer'), matching: find.byType(ListTile)));
    await drag(find.text('Player'), Offset(writer.center.dx, writer.top + 6));
    expect(await section('office'), ['player', 'writer', 'misc']);

    // The Games heading onto the upper half of the Office heading: before it.
    final office = tester.getRect(find.ancestor(of: find.text('Office'), matching: find.byType(InkWell)).first);
    await drag(find.text('Games'), Offset(office.center.dx, office.top + 4));
    final ids = [for (final g in (await tester.runAsync(() => call('groups.get')))!['groups'] as List) g['id']];
    expect(ids.indexOf('games'), ids.indexOf('office') - 1);

    // Writer onto New group: the name dialog, then a group with it.
    await drag(find.text('Writer'), tester.getCenter(find.text('New group')));
    expect(find.text('New group'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, 'Docs');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('Docs'), findsOneWidget);
    expect(await section('g1'), ['writer']);
  });

  testWidgets('wide window: folders, open one, Esc, Ctrl+G, drop on the bar, layouts', (tester) async {
    tester.view.physicalSize = const Size(1500, 1150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(MaterialApp(home: AppsPage(key: key, core: call, desktop: 'generic')));
    await settle(tester);
    final state = key.currentState!;
    expect(state.wide, isTrue);
    expect(state.showingFolders, isTrue);
    // Folders and the bar both name the groups; Other has Misc, so it shows.
    expect(find.text('Office'), findsNWidgets(2));
    expect(find.text('Other'), findsNWidgets(2));

    // A click on the folder (beside its icons) opens it: Writer as a card.
    await tester.tap(find.text('Office').first);
    await settle(tester);
    expect(state.wantedFilter, 'office');
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('Player'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(state.showingFolders, isTrue);

    // Ctrl+G: the next group in the bar.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(state.wantedFilter, 'office');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Misc's icon (in the Other folder) onto Media in the bar.
    final misc = find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Misc');
    final media = find.text('Media').last;
    final start = tester.getCenter(misc);
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(start, tester.getCenter(media), i / 10)!);
      await tester.pump();
    }
    await gesture.up();
    await settle(tester);
    final sections = (await tester.runAsync(() => call('apps.sections', {
      'view': 'groups',
      'keys': [p.join(home.path, 'data/applications/misc.desktop')],
    })))!;
    expect([for (final s in sections['sections'] as List) if ((s['keys'] as List).isNotEmpty) s['id']], ['media']);

    // The layouts: cards show every entry, saved in the settings.
    await tester.tap(find.byTooltip('Cards'));
    await settle(tester);
    expect(state.wideLayout, WideLayout.cards);
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('Misc'), findsOneWidget);
    expect((await tester.runAsync(() => call('settings.get')))!['wide_layout'], 'cards');
  });

  testWidgets('wide window, Cube: a face per group, turned by the footer, keys, a side face and a drag', (tester) async {
    tester.view.physicalSize = const Size(1500, 1150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final launched = <String>[];
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'apps.launch') {
        launched.add('${params['key']}');
        return {'started': true};
      }
      return call(method, params);
    }

    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(MaterialApp(home: AppsPage(key: key, core: fake, desktop: 'generic')));
    await settle(tester);
    final state = key.currentState!;
    await tester.tap(find.byTooltip('Cube'));
    await settle(tester);
    expect(state.wideLayout, WideLayout.cube);
    expect(state.showingCube, isTrue);
    expect((await tester.runAsync(() => call('settings.get')))!['wide_layout'], 'cube');
    final faces = [for (final (id, _) in state.folderSections) id];
    expect(faces.length, greaterThanOrEqualTo(3));
    // "All": the first group's face is in front, and its footer chip is marked.
    expect(state.cubeFront, faces.first);

    // A footer chip turns the cube to that group; its app starts with a click.
    await tester.tap(find.text('Office').last);
    await settle(tester);
    expect(state.cubeFront, 'office');
    expect(state.visibleApps.map((a) => a['name']), ['Writer']);
    await tester.tap(find.text('Writer'));
    await settle(tester);
    expect(launched, [state.byKey.keys.firstWhere((k) => k.endsWith('writer.desktop'))]);

    // Right, then Left before the turn is half done: back on Office, and the
    // cube shows it in front (it is no side face).
    final at = faces.indexOf('office');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(); // rebuilt while the turn has barely begun
    await settle(tester);
    expect(state.cubeFront, 'office');
    expect(find.byKey(ValueKey('cube-side-$at')), findsNothing);
    expect(find.byKey(ValueKey('cube-side-${(at + 1) % faces.length}')), findsOneWidget);

    // Right and Left turn it a face, Ctrl+G too (no stop on "All").
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(state.cubeFront, faces[(at + 1) % faces.length]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(state.cubeFront, 'office');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(state.cubeFront, faces[(at + 1) % faces.length]);

    // A click on a side face brings it to the front.
    final side = (at + 2) % faces.length;
    await tester.tap(find.byKey(ValueKey('cube-side-$side')));
    await settle(tester);
    expect(state.cubeFront, faces[side]);

    // A drag to the left turns it on by one face.
    final centre = tester.getCenter(find.byType(AppsPage));
    await tester.dragFrom(Offset(centre.dx, 300), const Offset(-500, 0));
    await settle(tester);
    expect(state.cubeFront, faces[(side + 1) % faces.length]);

    // The bottom-right option button flips the cube vertically to By origin,
    // and back to Groups again.
    expect(state.cubeByOrigin, isFalse);
    await tester.tap(find.byKey(const ValueKey('cube-axis-toggle')));
    await settle(tester);
    expect(state.cubeByOrigin, isTrue);
    expect(state.cubeFront, 'o-user');
    expect(find.text('Your own'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('cube-axis-toggle')));
    await settle(tester);
    expect(state.cubeByOrigin, isFalse);
    expect(state.cubeFront, faces.first);

    // Typing filters as a grid; the cube is back after.
    await tester.enterText(find.byType(TextField).first, 'pla');
    await settle(tester);
    expect(state.showingCube, isFalse);
    expect(find.text('Player'), findsOneWidget);
  });

  testWidgets('header: the buttons in a card, Settings dragged before Reload with a line where it lands', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AppsPage(core: call, desktop: 'generic')));
    await settle(tester);
    double x(String tooltip) => tester.getCenter(find.byTooltip(tooltip)).dx;
    expect(x('Reload') < x('Settings'), isTrue);
    expect(find.byKey(const ValueKey('header-drop-line')), findsNothing);

    final gesture = await tester.startGesture(tester.getCenter(find.byTooltip('Settings')));
    final target = tester.getCenter(find.byTooltip('Reload')) - const Offset(8, 0);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(tester.getCenter(find.byTooltip('Settings')), target, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The preview: a line before Reload.
    final line = find.byKey(const ValueKey('header-drop-line'));
    expect(line, findsOneWidget);
    expect(tester.getCenter(line).dx < x('Reload'), isTrue);
    await gesture.up();
    await settle(tester);
    expect(find.byKey(const ValueKey('header-drop-line')), findsNothing);
    expect(x('Settings') < x('Reload'), isTrue);
    final saved = (await tester.runAsync(() => call('settings.get')))!['header_order'] as List;
    expect(saved.indexOf('settings') < saved.indexOf('reload'), isTrue);

    // Dropped beside itself: nothing moves, no line is shown.
    final before = (await tester.runAsync(() => call('settings.get')))!['header_order'];
    final g2 = await tester.startGesture(tester.getCenter(find.byTooltip('Reload')));
    final self = tester.getCenter(find.byTooltip('Reload')) + const Offset(12, 0);
    for (var i = 1; i <= 6; i++) {
      await g2.moveTo(Offset.lerp(tester.getCenter(find.byTooltip('Reload')), self, i / 6)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const ValueKey('header-drop-line')), findsNothing);
    await g2.up();
    await settle(tester);
    expect((await tester.runAsync(() => call('settings.get')))!['header_order'], before);

    // A click is still a click: Settings opens.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    expect(find.text('SETTINGS'), findsOneWidget);
  });

  testWidgets('shown again: back on the app list, whatever page was open', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shown = ValueNotifier<int>(0);
    await tester.pumpWidget(MaterialApp(home: AppsPage(core: call, desktop: 'generic', shownAgain: shown)));
    await settle(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    expect(find.text('SETTINGS'), findsOneWidget);
    shown.value++;
    await settle(tester);
    expect(find.text('SETTINGS'), findsNothing);
    expect(find.text('Writer'), findsOneWidget);
  });

  testWidgets('settings: language at once, view buttons, filter field off', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => I18n.useTable('en', const {}));
    await tester.pumpWidget(MaprismaLauncherApp(core: call, look: const {}));
    await settle(tester);
    // No view buttons by default (Ctrl+G still switches).
    expect(find.byTooltip('Groups (Ctrl+G)'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    expect(find.text('SETTINGS'), findsOneWidget);
    await tester.tap(find.text('System'));
    await settle(tester);
    await tester.tap(find.text('Deutsch').last);
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    expect(find.text('EINSTELLUNGEN'), findsOneWidget);
    expect(find.text('Sprache'), findsOneWidget);
    expect((await tester.runAsync(() => call('settings.get')))!['language'], 'de');

    // View buttons when small: on.
    await tester.tap(find.byType(Switch).first);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byTooltip('Gruppen (Strg+G)'), findsOneWidget);
    expect(find.text('3 von 3 Apps'), findsOneWidget);
  });

  testWidgets('filter field off: typing still filters, the title shows it', (tester) async {
    tester.view.physicalSize = const Size(1500, 1150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => call('settings.set', {'key': 'filter_field', 'value': false}));
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(MaterialApp(home: AppsPage(key: key, core: call, desktop: 'generic')));
    await settle(tester);
    expect(find.byType(TextField), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await settle(tester);
    expect(find.text('Filter: wr'), findsOneWidget);
    expect(key.currentState!.filtered.map((a) => a['name']), ['Writer']);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);
    expect(find.text('Filter: w'), findsOneWidget);
  });

  testWidgets('F12: a picture of the window and its note; off in Settings', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A throwaway folder: no test picture in ~/Pictures.
    final shots = Directory(p.join(home.path, 'shots'));
    final settings = (await tester.runAsync(
      () => call('settings.set', {'key': 'screenshot_folder', 'value': shots.path}),
    ))!;
    await tester.pumpWidget(MaprismaLauncherApp(core: call, look: const {}, settings: settings));
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    for (var i = 0; i < 6; i++) {
      await settle(tester);
    }
    final pictures = shots.listSync().where((f) => f.path.endsWith('.png')).toList();
    expect(pictures, hasLength(1));
    expect(p.basename(pictures.single.path), startsWith('maprisma-launcher-'));
    expect(find.textContaining('Screenshot saved: '), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'Writer is cut off');
    await tester.tap(find.text('Done'));
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    final note = File(pictures.single.path.replaceFirst(RegExp(r'\.png$'), '.txt'));
    expect(note.readAsStringSync(), 'Writer is cut off\n');

    // While the app's terminal runs (sudo may want the password): no picture, no note field.
    TerminalPage.running.value++;
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    TerminalPage.running.value--;
    expect(shots.listSync().where((f) => f.path.endsWith('.png')), hasLength(1));
    expect(find.byKey(const ValueKey('screenshot-note')), findsNothing);

    // Off in Settings: F12 does nothing.
    final off = (await tester.runAsync(() => call('settings.set', {'key': 'screenshot_key', 'value': false})))!;
    await tester.pumpWidget(MaprismaLauncherApp(key: UniqueKey(), core: call, look: const {}, settings: off));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    expect(shots.listSync().where((f) => f.path.endsWith('.png')), hasLength(1));
    expect(find.textContaining('Screenshot saved: '), findsNothing);
  });

  testWidgets('Uninstall…: your own entry goes to the trash after the question', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(MaterialApp(home: AppsPage(key: key, core: call, desktop: 'generic')));
    await settle(tester);
    await tester.tapAt(tester.getCenter(find.text('Misc')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Uninstall…'));
    await settle(tester);
    expect(find.text('Do you want to uninstall Misc?'), findsOneWidget);
    expect(find.textContaining('to the trash'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
    await settle(tester);
    await settle(tester);
    expect(File(p.join(home.path, 'data/applications/misc.desktop')).existsSync(), isFalse);
    expect(File(p.join(home.path, 'data/Trash/files/misc.desktop')).existsSync(), isTrue);
    expect(find.text('Misc'), findsNothing);
  });

  testWidgets('Quit: only for a running app with a tray Quit, and it asks the core to click it', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final asked = <String>[];
    String? misc;
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
      switch (method) {
        case 'apps.running':
          final apps = (await call('apps.list'))['apps'] as List;
          misc = apps.firstWhere((a) => a['name'] == 'Misc')['key'] as String;
          return {'running': [misc]};
        case 'apps.quit_check':
          asked.add('check ${params['key']}');
          return {'label': 'Quit Misc'};
        case 'apps.quit':
          asked.add('quit ${params['key']}');
          return {'clicked': true};
      }
      return call(method, params);
    }

    await tester.pumpWidget(MaterialApp(home: AppsPage(core: fake, desktop: 'generic')));
    await settle(tester);
    // Not running: no Quit, not even asked.
    await tester.tapAt(tester.getCenter(find.text('Writer')), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Quit'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.tapAt(tester.getCenter(find.text('Misc')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Quit'));
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    await settle(tester);
    expect(asked, ['check $misc', 'quit $misc']);
  });

  testWidgets('Close: for an app with multiple windows, a submenu closes all or one chosen window', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final closed = <Map<String, dynamic>>[];
    String? misc;
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
      switch (method) {
        case 'apps.running':
          final apps = (await call('apps.list'))['apps'] as List;
          misc = apps.firstWhere((a) => a['name'] == 'Misc')['key'] as String;
          return {'running': [misc], 'states': {misc: 'active'}};
        case 'apps.windows':
          return {
            'windows': [
              {'address': '0x1', 'title': 'First Misc', 'workspace': 1},
              {'address': '0x2', 'title': 'Second Misc', 'workspace': 2},
            ],
          };
        case 'apps.close':
          closed.add(params);
          return {'closed': params['address'] == null ? 2 : 1};
        case 'apps.quit_check':
          return {'label': null};
      }
      return call(method, params);
    }

    await tester.pumpWidget(MaterialApp(home: AppsPage(core: fake, desktop: 'omarchy')));
    await settle(tester);
    await tester.tapAt(tester.getCenter(find.text('Misc')), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Switch to window'), findsOneWidget);
    await tester.tap(find.text('Close all windows (2)'));
    await settle(tester);
    // Submenu: Close all windows (2), or pick an individual window.
    expect(find.text('First Misc'), findsOneWidget);
    expect(find.text('Second Misc'), findsOneWidget);
    await tester.tap(find.text('First Misc'));
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await settle(tester);
    expect(closed, [
      {'key': misc, 'address': '0x1'},
    ]);

    await tester.tapAt(tester.getCenter(find.text('Misc')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Close all windows (2)'));
    await settle(tester);
    await tester.tap(find.text('Close all windows (2)').last);
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await settle(tester);
    expect(closed.last, {'key': misc});
  });

  testWidgets('a click that moves a pixel on a folder icon does not move the app to the end of its group', (tester) async {
    tester.view.physicalSize = const Size(1500, 1150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final placed = <Map>[];
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'groups.place') placed.add(params);
      return call(method, params);
    }

    await tester.pumpWidget(MaterialApp(home: AppsPage(core: fake, desktop: 'generic')));
    await settle(tester);
    final writer = find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Writer');
    final start = tester.getCenter(writer);
    // A mouse: a drag starts after a pixel or so (a touch needs 18).
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 4; i++) {
      await gesture.moveTo(start + Offset(i * 3.0, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await settle(tester);
    expect(placed, isEmpty);
  });

  testWidgets('Install apps: search, review with the command and the AUR warning', (tester) async {
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final asked = <String>[];
    Map<String, dynamic>? terminal;
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
      asked.add(method);
      if (method == 'term.start') terminal = params;
      return switch (method) {
        'term.start' => {'id': 't1', 'command': 'yay -S -- gimp-git'},
        'term.read' => {'data': '', 'ended': true, 'code': 0},
        'packages.managers' => {
          'managers': [
            {'id': 'pacman', 'label': 'pacman', 'program': 'pacman', 'enabled': true},
            {'id': 'aur', 'label': 'AUR', 'program': 'yay', 'enabled': true},
          ],
        },
        'packages.search' => {
          'results': [
            {'manager': 'pacman', 'package': 'gimp', 'version': '3.2', 'description': 'GNU Image Manipulation Program'},
            {'manager': 'aur', 'package': 'gimp-git', 'version': 'r1', 'description': 'GIMP from git', 'aur': true},
            {'manager': 'pacman', 'package': 'krita', 'version': '5', 'description': 'Paint', 'installed': true},
          ],
        },
        'packages.install_plan' => {
          'command': '${params['manager'] == 'aur' ? 'yay' : 'sudo pacman'} -S -- ${params['package']}',
          'aur': params['manager'] == 'aur',
        },
        _ => {'started': true},
      };
    }

    await tester.pumpWidget(MaterialApp(home: InstallPage(core: fake)));
    await settle(tester);
    expect(find.text('Searches: pacman, AUR'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'gimp');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(find.text('Install…'), findsNWidgets(2)); // krita is installed already
    await tester.tap(find.text('Install…').last);
    await settle(tester);
    expect(find.text('yay -S -- gimp-git'), findsOneWidget);
    expect(find.textContaining('Arch User Repository'), findsOneWidget);
    await tester.tap(find.text('Install in terminal'));
    await settle(tester);
    // In the app's own terminal now: the package the search found.
    expect(asked, isNot(contains('packages.install')));
    expect(terminal, containsPair('action', 'install'));
    expect(terminal, containsPair('package', 'gimp-git'));
    expect(terminal, containsPair('manager', 'aur'));
    expect(find.text('Installing gimp-git…'), findsOneWidget);
    expect(find.text('Done.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settle(tester);
  });

  testWidgets('legend: only the hidden ones, Esc back; Details as a page', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await call('apps.list');
      await call('apps.hide', {'key': p.join(home.path, 'data/applications/misc.desktop'), 'hidden': true});
    });
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(MaterialApp(home: AppsPage(key: key, core: call, desktop: 'generic')));
    await settle(tester);
    expect(find.text('Misc'), findsNothing);
    await tester.tap(find.byTooltip('What the marks mean'));
    await settle(tester);
    await tester.tap(find.text('Hidden: shown only with the eye button'));
    await settle(tester);
    expect(key.currentState!.markFilter, 'hidden');
    expect(find.text('Misc'), findsOneWidget);
    expect(find.text('Writer'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(key.currentState!.markFilter, isNull);
    expect(find.text('Writer'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Writer')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Details…'));
    await settle(tester);
    expect(find.text('DETAILS'), findsOneWidget);
    expect(find.text(p.join(home.path, 'data/applications/writer.desktop')), findsOneWidget);
    expect(find.text('Office'), findsOneWidget); // its group
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);
    expect(find.text('DETAILS'), findsNothing);
  });

  testWidgets('Shortcut… opens its page; a generic desktop has nowhere to write', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AppsPage(core: call, desktop: 'generic')));
    await settle(tester);
    await tester.tapAt(tester.getCenter(find.text('Writer')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Shortcut…'));
    await settle(tester);
    expect(find.text('Shortcuts for Writer'), findsOneWidget);
    expect(find.textContaining('Global shortcuts need GNOME, COSMIC or Omarchy'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text('Shortcuts for Writer'), findsNothing);
  });

  testWidgets('Change icon: a theme icon is used, and reset again', (tester) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final svg = File(p.join(home.path, 'data/icons/hicolor/scalable/apps/writer-alt.svg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>');
    final key = GlobalKey<AppsPageState>();
    await tester.pumpWidget(MaterialApp(home: AppsPage(key: key, core: call, desktop: 'generic')));
    await settle(tester);
    await tester.tapAt(tester.getCenter(find.text('Writer')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Change icon…'));
    await settle(tester);
    await settle(tester);
    expect(find.text('Installed icons'), findsOneWidget);
    await tester.tap(find.text('writer-alt'));
    await settle(tester);
    await settle(tester);
    final writer = key.currentState!.apps.firstWhere((a) => a['name'] == 'Writer');
    expect(writer['icon_file'], svg.path);
    expect(writer['icon_chosen'], isTrue);
    final saved = jsonDecode(File(p.join(home.path, '.config/maprisma-launcher/icons.json')).readAsStringSync());
    expect(saved, {'writer': 'writer-alt'});

    await tester.tapAt(tester.getCenter(find.text('Writer')), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Change icon…'));
    await settle(tester);
    await tester.tap(find.text('Use its own icon'));
    await settle(tester);
    await settle(tester);
    expect(key.currentState!.apps.firstWhere((a) => a['name'] == 'Writer')['icon_chosen'], isFalse);
  });
}
