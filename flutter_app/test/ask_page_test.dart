import 'dart:async';

import 'package:maprisma_launcher/ask_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final asked = <Map<String, dynamic>>[];
  var helpersReady = true;
  Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
    asked.add({'method': method, ...params});
    return switch (method) {
      'ask.helpers' => {
        'helpers': [
          {'command': 'claude', 'name': 'Claude Code', 'installed': helpersReady, 'signed_in': helpersReady},
          {'command': 'agy', 'name': 'Antigravity', 'installed': false, 'signed_in': false},
        ],
      },
      'ask.run' when '${params['request']}'.contains('hidden') => {
        'action': 'list_hidden',
        'apps': ['k4'],
      },
      'ask.run' when '${params['request']}'.contains('update') => {
        'action': 'update',
        'apps': ['k2', 'k3'],
      },
      'ask.run' when params['answer'] == null && '${params['request']}'.contains('editor') => {
        'action': 'clarify',
        'question': 'What do you want to edit?',
        'choices': ['Photos', 'Videos'],
      },
      'ask.run' => {
        'action': 'install',
        'summary': 'GIMP edits photos.',
        'picks': [
          {'manager': 'pacman', 'package': 'gimp', 'version': '3.2', 'reason': 'Edits photos', 'description': 'GNU'},
        ],
        'installed': ['k1'],
      },
      'packages.install_plan' => {'command': 'sudo pacman -S -- gimp', 'aur': false},
      _ => <String, dynamic>{},
    };
  }

  final apps = {
    'k1': <String, dynamic>{'key': 'k1', 'name': 'Pinta', 'description': 'Paint'},
    'k2': <String, dynamic>{'key': 'k2', 'name': 'Code', 'description': 'Editor'},
    'k3': <String, dynamic>{'key': 'k3', 'name': 'Flat', 'description': 'A Flatpak'},
    'k4': <String, dynamic>{'key': 'k4', 'name': 'Old Tool', 'description': 'Hidden', 'hidden': true},
  };
  final opened = <String>[];
  AppActions actions() => (
    open: (app) => opened.add('${app['name']}'),
    uninstall: (app) async {},
    update: (app) async {},
    updateSystem: () async {},
    details: (app) async {},
    updateKind: (app) => null,
    setHidden: (app, hidden) async {},
  );

  testWidgets('no helper or AI disabled: shows Install apps with a hint why Ask AI is not available', (tester) async {
    helpersReady = false;
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.text('To get app suggestions from an AI, connect an AI helper:'), findsOneWidget);
    expect(find.text('Not installed'), findsNWidgets(2));
    expect(find.text('Without AI, Install apps searches the packages by name.'), findsOneWidget);
    expect(find.text('INSTALL APPS'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    helpersReady = true;

    await tester.pumpWidget(
      MaterialApp(
        home: AskPage(key: UniqueKey(), core: fake, apps: apps, actions: actions(), aiEnabled: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Without AI, Install apps searches the packages by name.'), findsOneWidget);
    expect(find.text('INSTALL APPS'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('ask: clarify with choices, then suggestions with the review', (tester) async {
    asked.clear();
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.textContaining('Claude Code plan or tokens'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'I need an editor');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('What do you want to edit?'), findsOneWidget);
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    final second = asked.where((a) => a['method'] == 'ask.run').last;
    expect(second['request'], 'I need an editor');
    expect(second['answer'], 'Photos');
    expect(second['helper'], 'claude');
    expect(find.text('GIMP edits photos.'), findsOneWidget);
    expect(find.text('Pinta'), findsOneWidget); // already installed
    await tester.tap(find.text('Open'));
    expect(opened, ['Pinta']);
    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();
    expect(find.text('sudo pacman -S -- gimp'), findsOneWidget);
    // Exactly the two clicks spent tokens.
    expect(asked.where((a) => a['method'] == 'ask.run'), hasLength(2));
  });

  testWidgets('update: a package goes with the system, a Flatpak alone with a spinner', (tester) async {
    final done = <String>[];
    final flatpak = Completer<void>();
    final actions = (
      open: (Map app) {},
      uninstall: (Map app) async {},
      update: (Map app) async {
        done.add('flatpak ${app['name']}');
        await flatpak.future;
      },
      updateSystem: () async => done.add('system'),
      details: (Map app) async {},
      setHidden: (Map app, bool hidden) async {},
      updateKind: (Map app) => switch (app['key']) {
        'k2' => 'package',
        'k3' => 'flatpak',
        _ => null,
      },
    );
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'what can I update');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    // Code (a package): "Update system…" in its row and below the list.
    expect(find.text('Update system…'), findsNWidgets(2));
    await tester.tap(find.text('Update system…').first);
    await tester.pump();
    expect(done, ['system']);
    // Flat (a Flatpak): Update, then a spinner until it is done.
    await tester.tap(find.widgetWithText(TextButton, 'Update'));
    await tester.pump();
    expect(done, ['system', 'flatpak Flat']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    flatpak.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.widgetWithText(TextButton, 'Update'), findsOneWidget);
  });

  testWidgets('hidden apps: listed with Unhide; a click unhides, then the button offers Hide', (tester) async {
    final changed = <String>[];
    final base = actions();
    final AppActions withHide = (
      open: base.open,
      uninstall: base.uninstall,
      update: base.update,
      updateSystem: base.updateSystem,
      details: base.details,
      updateKind: base.updateKind,
      setHidden: (Map app, bool hidden) async => changed.add('${app['key']} $hidden'),
    );
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: withHide)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'list my hidden apps');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('1 hidden app'), findsOneWidget);
    expect(find.text('Old Tool'), findsOneWidget);
    await tester.tap(find.text('Unhide'));
    await tester.pumpAndSettle();
    expect(changed, ['k4 false']);
    expect(find.text('Hide'), findsOneWidget);
  });
}
