import 'dart:async';

import 'package:maprisma_launcher/ask_page.dart';
import 'package:maprisma_launcher/backend.dart';
import 'package:maprisma_launcher/shortcut_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_fake.dart';

void main() {
  final asked = <Map<String, dynamic>>[];
  var helpersReady = true;
  var sharedChoice = 'auto';
  List<String>? savedPrompts;
  // As the core: the shared choice when installed, else the first ready one.
  Map<String, dynamic> helperState() {
    final helpers = [
      {'command': 'claude', 'name': 'Claude Code', 'installed': helpersReady, 'signed_in': helpersReady, 'verified': true},
      {'command': 'agy', 'name': 'Antigravity', 'installed': false, 'signed_in': false, 'verified': true},
      if (helpersReady)
        {'command': 'gemini', 'name': 'Gemini CLI', 'installed': true, 'signed_in': true, 'catalog': true, 'verified': false},
    ];
    final installed = [for (final h in helpers) if (h['installed'] == true) h['command']];
    return {
      'helpers': helpers,
      'choice': sharedChoice,
      'chosen': installed.contains(sharedChoice) ? sharedChoice : installed.firstOrNull,
    };
  }

  Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
    asked.add({'method': method, ...params});
    if (method == 'settings.set' && params['key'] == 'ask_prompts') {
      final value = params['value'];
      savedPrompts = value == null ? null : List<String>.from(value as List);
    }
    if (method == 'settings.get' || method == 'settings.set') return {'ask_prompts': savedPrompts};
    return switch (method) {
      'ask.helpers' => helperState(),
      'ai.helper.set' => (() {
        sharedChoice = params['helper'] as String;
        return helperState();
      })(),
      'ask.run' when '${params['request']}' == 'can you list the artcraft apps from github' => {
        'action': 'install', 'source': 'github', 'picks': [{
          'manager': 'github', 'package': 'storytold/craft-launcher', 'installable': false,
          'repository': 'https://github.com/storytold/craft-launcher', 'description': 'ArtCraft apps',
        }],
      },
      'ask.run' when '${params['request']}' == 'install craft-launcher from github' => {
        'action': 'install', 'source': 'github', 'picks': [{
          'manager': 'github', 'package': 'storytold/craft-launcher', 'version': 'v1', 'installable': true,
          'repository': 'https://github.com/storytold/craft-launcher', 'asset': 'craft-x86_64.AppImage',
        }],
      },
      'ask.run' when '${params['request']}' == 'install pdfcraft from getartcraft.com' => {
        'action': 'install', 'source': 'github', 'web': true, 'summary': 'The official site links to GitHub.',
        'picks': [{
          'manager': 'github', 'package': 'storytold/pdfcraft', 'version': 'v1', 'installable': true,
          'repository': 'https://github.com/storytold/pdfcraft', 'asset': 'pdfcraft-1-linux-x86_64.AppImage',
        }],
        'web_found': [{'site': 'getartcraft.com', 'repository': 'storytold/pdfcraft'}],
      },
      'ask.run' when '${params['request']}'.startsWith('zzqq') => {
        'action': 'install', 'picks': [], 'installed': [], 'queries': ['zzqq'],
        'web_search': '${params['request']}'.endsWith('agy') ? 'unsupported' : 'off',
      },
      'packages.install_plan' when params['manager'] == 'github' => {
        'github': true, 'command': 'download; sha256sum --check; install',
      },
      'ask.run' when '${params['request']}'.contains('shortcuts of all') => {
        'action': 'shortcuts',
        'apps': ['k1'],
      },
      'ask.run' when '${params['request']}'.startsWith('Add a shortcut for') => {
        'action': 'add_shortcut',
        'apps': ['k1'],
        'mods': ['SUPER', 'ALT'],
        'key': 'P',
      },
      'shortcuts.state' => {
        'available': true,
        'desktop': 'Omarchy',
        'default_mods': ['SUPER', 'SHIFT'],
        'actions': [],
        'shortcuts': [
          {'mods': ['SUPER', 'SHIFT'], 'key': 'P', 'label': 'Super + Shift + P', 'source': 'launcher', 'action': '', 'replaces': ''},
        ],
        'disabled': [],
        if ((params['mods'] as List? ?? const []).isNotEmpty)
          'keys': [
            for (final row in keyRows)
              for (final k in row) {'key': k, 'label': k, 'level': 'free', 'owner': ''},
          ],
      },
      'ask.run' when '${params['request']}'.contains('local model') =>
        throw ServiceError('helper_failed', 'Bad state: llama-server.service did not answer.'),
      'ask.run' when '${params['request']}'.contains('hidden') => {
        'action': 'list_hidden',
        'apps': ['k4'],
      },
      'ask.run' when '${params['request']}'.contains('update') => {
        'action': 'update',
        'apps': ['k2', 'k3', 'k5'],
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
    'k5': <String, dynamic>{'key': 'k5', 'name': 'Image App', 'description': 'An AppImage'},
  };
  final opened = <String>[];
  AppActions actions() => (
    open: (app) => opened.add('${app['name']}'),
    uninstall: (app) async {},
    uninstallAll: (apps) async {},
    update: (app) async {},
    updateAppImage: (app) async {},
    updateSystem: () async {},
    details: (app) async {},
    updateKind: (app) => null,
    setHidden: (app, hidden) async {},
  );

  Future<void> askFor(WidgetTester tester, String text) async {
    asked.clear();
    helpersReady = true;
    await tester.pumpWidget(MaterialApp(home: AskPage(key: UniqueKey(), core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
  }

  testWidgets('no per-question web switch; nothing found says when web search is off or needs Claude Code',
      (tester) async {
    await askFor(tester, 'zzqq');
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(asked.where((a) => a['method'] == 'ask.run').single.containsKey('web'), false);
    expect(find.text('Web search is off (Maprisma Manager › AI).'), findsOneWidget);
    await askFor(tester, 'zzqq agy');
    expect(find.text('Web search needs Claude Code as the AI helper (Maprisma Manager › AI).'), findsOneWidget);
  });

  testWidgets('web discovery shows where the repository was found; install uses the checked preview', (tester) async {
    await askFor(tester, 'install pdfcraft from getartcraft.com');
    expect(find.text('Found on the web: getartcraft.com → github.com/storytold/pdfcraft'), findsOneWidget);
    expect(find.text('GitHub repositories'), findsOneWidget);
    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();
    expect(find.text('Downloads to Applications and verifies SHA-256. No password is needed.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('listing shows repositories without installers and opens the source', (tester) async {
    await askFor(tester, 'can you list the artcraft apps from github');
    expect(find.text('GitHub repositories'), findsOneWidget);
    expect(find.textContaining('storytold/craft-launcher'), findsOneWidget);
    expect(find.text('Install…'), findsNothing);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(asked.where((a) => a['method'] == 'open.url').single['url'], 'https://github.com/storytold/craft-launcher');
    expect(asked.where((a) => a['method'] == 'packages.install_plan'), isEmpty);
  });

  testWidgets('GitHub suggestion keeps its repository and uses the install preview', (tester) async {
    await askFor(tester, 'install craft-launcher from github');
    expect(find.text('GitHub'), findsOneWidget);
    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();
    expect(find.text('https://github.com/storytold/craft-launcher'), findsOneWidget);
    expect(find.text('Downloads to Applications and verifies SHA-256. No password is needed.'), findsOneWidget);
    expect(find.text('A terminal runs this and asks for your password:'), findsNothing);
    expect(asked.where((a) => a['method'] == 'packages.install' || a['method'] == 'terminal.start'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

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

  testWidgets('update: packages use the system, Flatpaks and AppImages update alone', (tester) async {
    final done = <String>[];
    final flatpak = Completer<void>();
    final actions = (
      open: (Map app) {},
      uninstall: (Map app) async {},
      uninstallAll: (List<Map> apps) async {},
      update: (Map app) async {
        done.add('flatpak ${app['name']}');
        await flatpak.future;
      },
      updateAppImage: (Map app) async => done.add('appimage ${app['name']}'),
      updateSystem: () async => done.add('system'),
      details: (Map app) async {},
      setHidden: (Map app, bool hidden) async {},
      updateKind: (Map app) => switch (app['key']) {
        'k2' => 'package',
        'k3' => 'flatpak',
        'k5' => 'appimage',
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
    await tester.tap(find.widgetWithText(TextButton, 'Update').first);
    await tester.pump();
    expect(done, ['system', 'flatpak Flat']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    flatpak.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.widgetWithText(TextButton, 'Update'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, 'Update').last);
    await tester.pumpAndSettle();
    expect(done, ['system', 'flatpak Flat', 'appimage Image App']);
  });

  testWidgets('update all: Flatpaks and AppImages one after another, then the system once', (tester) async {
    final done = <String>[];
    final flatpak = Completer<void>();
    final actions = (
      open: (Map app) {},
      uninstall: (Map app) async {},
      uninstallAll: (List<Map> apps) async {},
      update: (Map app) async {
        done.add('flatpak ${app['name']}');
        await flatpak.future;
      },
      updateAppImage: (Map app) async => done.add('appimage ${app['name']}'),
      updateSystem: () async => done.add('system'),
      details: (Map app) async {},
      setHidden: (Map app, bool hidden) async {},
      updateKind: (Map app) => switch (app['key']) {
        'k2' => 'package',
        'k3' => 'flatpak',
        'k5' => 'appimage',
        _ => null,
      },
    );
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'what can I update');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    // On the heading's line, right above the row buttons.
    final all = find.widgetWithText(TextButton, 'Update all');
    expect(all, findsOneWidget);
    expect(tester.getTopLeft(all).dy, lessThan(tester.getTopLeft(find.text('Update system…').first).dy));
    await tester.tap(all);
    await tester.pump();
    expect(done, ['flatpak Flat']);                     // one after another: the Flatpak first
    expect(find.widgetWithText(TextButton, 'Update all'), findsNothing);   // a spinner while it runs
    flatpak.complete();
    await tester.pumpAndSettle();
    expect(done, ['flatpak Flat', 'appimage Image App', 'system']);   // packages: the system, once, last
    expect(find.widgetWithText(TextButton, 'Update all'), findsOneWidget);
  });

  testWidgets('hidden apps: listed with Unhide; a click unhides, then the button offers Hide', (tester) async {
    final changed = <String>[];
    final base = actions();
    final AppActions withHide = (
      open: base.open,
      uninstall: base.uninstall,
      uninstallAll: base.uninstallAll,
      update: base.update,
      updateAppImage: base.updateAppImage,
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

  testWidgets('suggestions: save what you typed, edit one in place (Esc cancels), remove, back to built-in', (tester) async {
    asked.clear();
    savedPrompts = null;
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.text('Suggest a photo editor'), findsOneWidget);
    expect(find.byTooltip('Back to the built-in suggestions'), findsNothing);
    await tester.enterText(find.byType(TextField), '  Find a music player ');
    await tester.tap(find.byTooltip('Save as suggestion'));
    await tester.pumpAndSettle();
    expect(savedPrompts, [
      'Suggest a photo editor', 'Find an app to cut videos', 'Which installed app opens PDFs?',
      'What can I update?', 'Find a music player',
    ]);
    expect(find.text('Find a music player'), findsOneWidget);
    await tester.tap(find.byTooltip('Save as suggestion'));               // twice: not again
    await tester.pumpAndSettle();
    expect(savedPrompts, hasLength(5));
    expect(find.text('That is already a suggestion.'), findsOneWidget);
    // Edit: Esc cancels only the edit.
    await tester.tap(find.byTooltip('Edit suggestion').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('prompt-edit')), 'Find a podcast player');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('prompt-edit')), findsNothing);
    expect(find.byType(AskPage), findsOneWidget);
    expect(savedPrompts!.last, 'Find a music player');
    await tester.tap(find.byTooltip('Edit suggestion').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('prompt-edit')), 'Find a podcast player');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(savedPrompts!.last, 'Find a podcast player');
    await tester.tap(find.byTooltip('Remove suggestion').first);
    await tester.pumpAndSettle();
    expect(savedPrompts!.first, 'Find an app to cut videos');
    expect(find.text('Suggest a photo editor'), findsNothing);
    await tester.tap(find.byTooltip('Back to the built-in suggestions'));
    await tester.pumpAndSettle();
    expect(savedPrompts, isNull);
    expect(find.text('Suggest a photo editor'), findsOneWidget);
    expect(asked.where((a) => a['method'] == 'ask.run'), isEmpty);
  });

  testWidgets('back from an answer: Esc, Backspace and Back return to the Ask AI start, then leave', (tester) async {
    asked.clear();
    savedPrompts = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
            builder: (_) => AskPage(core: fake, apps: apps, actions: actions()),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    Future<void> answer() async {
      await tester.tap(find.text('Suggest a photo editor').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Edit suggestion'), findsNothing);       // the answer replaces the start
    }

    await answer();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AskPage), findsOneWidget);
    expect(find.byTooltip('Edit suggestion'), findsNWidgets(4));
    await answer();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit suggestion'), findsNWidgets(4));
    await answer();
    await tester.enterText(find.byType(TextField), '');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);        // empty field: back
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit suggestion'), findsNWidgets(4));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);           // from the start: out
    await tester.pumpAndSettle();
    expect(find.byType(AskPage), findsNothing);
  });

  testWidgets('Enter asks; Ctrl+Enter only adds a line; the hint says so', (tester) async {
    asked.clear();
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter asks, Ctrl+Enter: new line.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'list my hidden apps');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'list my hidden apps\n');
    expect(asked.where((a) => a['method'] == 'ask.run'), isEmpty);
    // Enter: the field's send action.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(asked.where((a) => a['method'] == 'ask.run'), hasLength(1));
  });

  testWidgets('a helper that fails says why (the local model server)', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ask the local model');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('The helper did not answer. llama-server.service did not answer.'), findsOneWidget);
  });

  testWidgets('shortcuts: the hint card lists them as cards; ✕ removes; Add shows the card with the proposed key', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    asked.clear();
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.text('Manage shortcuts for an app'), findsOneWidget);
    await tester.tap(find.text('List all shortcuts'));
    await tester.pumpAndSettle();
    expect(find.text('Shortcuts of 1 app'), findsOneWidget);
    expect(find.text('Shortcuts for Pinta'), findsOneWidget);
    expect(find.text('Super'), findsOneWidget);
    // Only the list: no key map until "Add a shortcut…".
    expect(find.byKey(const ValueKey('shortcut-assign')), findsNothing);
    await tester.tap(find.byTooltip('Remove this shortcut'));
    await tester.pumpAndSettle();
    final removed = asked.where((a) => a['method'] == 'shortcuts.remove').single;
    expect(removed['key'], 'k1');
    expect(removed['combo'], {'mods': ['SUPER', 'SHIFT'], 'key': 'P'});

    // "Add a shortcut…" starts the request; the app's name is the user's.
    await tester.pumpWidget(MaterialApp(home: AskPage(key: UniqueKey(), core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'Add a shortcut…'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(field.text, 'Add a shortcut for ');
    expect(asked.where((a) => a['method'] == 'ask.run'), hasLength(1)); // only the list above
    await tester.enterText(find.byType(TextField), 'Add a shortcut for Pinta');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Add a shortcut'), findsWidgets);
    // The proposal is preset; nothing is written before Assign.
    expect(find.text('Alt'), findsWidgets);
    expect(asked.where((a) => a['method'] == 'shortcuts.set'), isEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('shortcut-assign')));
    await tester.tap(find.byKey(const ValueKey('shortcut-assign')));
    await tester.pumpAndSettle();
    final set = asked.where((a) => a['method'] == 'shortcuts.set').single;
    expect([set['key'], set['mods'], set['combo_key']], ['k1', ['SUPER', 'ALT'], 'P']);
  });

  testWidgets('the Helper drop-down shows the shared choice and writes it', (tester) async {
    asked.clear();
    sharedChoice = 'auto';
    addTearDown(() => sharedChoice = 'auto');
    await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.text('Automatic · Claude Code'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ask-helper')));
    await tester.pumpAndSettle();
    // Automatic first, then every installed helper; an untested catalog entry says so.
    expect(find.text('Gemini CLI (untested)'), findsOneWidget);
    expect(find.text('Antigravity'), findsNothing, reason: 'not installed');
    await tester.tap(find.text('Gemini CLI (untested)').last);
    await tester.pumpAndSettle();
    expect(asked.where((a) => a['method'] == 'ai.helper.set').single['helper'], 'gemini');
    expect(sharedChoice, 'gemini');
    await tester.enterText(find.byType(TextField), 'Suggest a photo app');
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    expect(asked.where((a) => a['method'] == 'ask.run').last['helper'], 'gemini');

    // Chosen elsewhere (Maprisma Manager › AI), not installed here: Automatic is shown, the file stays.
    sharedChoice = 'grok';
    await tester.pumpWidget(MaterialApp(home: AskPage(key: UniqueKey(), core: fake, apps: apps, actions: actions())));
    await tester.pumpAndSettle();
    expect(find.text('Automatic · Claude Code'), findsOneWidget);
    expect(sharedChoice, 'grok');
  });

  group('mic button (fake maprisma-voice)', () {
    late FakeVoice voice;
    setUp(() async => voice = await FakeVoice.create());
    tearDown(() => voice.dispose());

    testWidgets('hidden while the voice service is not ready', (tester) async {
      voice.status(ready: false);
      await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
      await settle(tester);
      expect(find.byKey(const ValueKey('voice-mic')), findsNothing);
      expect(find.byTooltip('Save as suggestion'), findsOneWidget);
    });

    testWidgets('ready: click, click puts the words into the request at the cursor', (tester) async {
      await tester.pumpWidget(MaterialApp(home: AskPage(core: fake, apps: apps, actions: actions())));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'Find');
      await tester.tap(find.byKey(const ValueKey('voice-mic')));
      await settle(tester);
      expect(find.text('hello'), findsOneWidget); // the partial, greyed under the field
      await tester.tap(find.byKey(const ValueKey('voice-mic')));
      await settle(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Find hello world');
      expect(find.text('hello'), findsNothing);
      expect(voice.args.last, 'dictate --events --release --app-id com.maprisma.Launcher');
    });
  });
}
