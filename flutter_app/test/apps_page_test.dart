/// The apps page against the real core on a fixture home: views, folding,
/// moving an entry to a new group, hiding.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appmanager/apps_page.dart';
import 'package:appmanager_core/appmanager_core.dart';
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
        'APPMANAGER_DESKTOP': 'generic',
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
      await tester.pump();
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
        await tester.pump(const Duration(milliseconds: 16));
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
      await tester.pump(const Duration(milliseconds: 16));
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
}
