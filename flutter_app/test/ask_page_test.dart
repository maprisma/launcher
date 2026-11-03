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
  };
  final opened = <String>[];
  AppActions actions() => (
    open: (app) => opened.add('${app['name']}'),
    uninstall: (app) async {},
    update: (app) async {},
    updateSystem: () async {},
    details: (app) async {},
    hasUpdate: (app) => false,
  );

  testWidgets('no helper: how to get one, and Install apps without AI', (tester) async {
    helpersReady = false;
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.text('To get app suggestions from an AI, connect an AI helper:'), findsOneWidget);
    expect(find.text('Not installed'), findsNWidgets(2));
    expect(find.text('Install apps'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    helpersReady = true;
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
}
