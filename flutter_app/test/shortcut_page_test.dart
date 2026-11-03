/// The Shortcut… page against a fake core: the current shortcuts, the key
/// map coloured by owner, modifier chips, picking and assigning a key,
/// changing and removing one, the action choice, Esc.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/shortcut_page.dart';

void main() {
  final calls = <Map<String, dynamic>>[];
  var available = true;
  var assigned = false;

  Map<String, dynamic> keyInfo(String key, List mods) {
    final level = switch ((mods.join('+'), key)) {
      ('SUPER', 'Q') => ('desktop', 'Close window'),
      ('SUPER', 'E') => ('custom', 'Files'),
      ('SUPER+ALT', 'F') when assigned => ('same', 'Firefox'),
      ('SUPER+SHIFT', 'B') => ('launcher', 'Chromium'),
      _ => ('free', ''),
    };
    return {'key': key, 'label': key, 'level': level.$1, 'owner': level.$2};
  }

  Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add({'method': method, ...params});
    switch (method) {
      case 'shortcuts.state':
        final mods = params['mods'] as List? ?? const [];
        if (!available) return {'available': false, 'desktop': null, 'default_mods': ['SUPER', 'SHIFT'], 'actions': []};
        return {
          'available': true,
          'desktop': 'GNOME',
          'default_mods': ['SUPER', 'SHIFT'],
          'actions': [
            {'id': 'new-private-window', 'name': 'New Private Window'},
          ],
          'shortcuts': [
            if (assigned)
              {'mods': ['SUPER', 'ALT'], 'key': 'F', 'label': 'Super + Alt + F', 'source': 'launcher', 'action': '', 'replaces': '', 'duplicate': false},
            {'mods': ['SUPER'], 'key': '1', 'label': 'Super + 1', 'source': 'external', 'action': '', 'file': 'GNOME', 'description': 'Switch to application 1'},
          ],
          'disabled': [],
          if (mods.isNotEmpty)
            'keys': [for (final row in keyRows) for (final k in row) keyInfo(k, mods)]
          else
            'suggestions': [
              {'mods': ['SUPER', 'ALT'], 'key': 'F', 'label': 'Super + Alt + F'},
            ],
        };
      case 'shortcuts.set':
        assigned = true;
        return {'saved': true};
      case 'shortcuts.remove':
        assigned = false;
        return {'saved': true};
      default:
        return {'saved': true};
    }
  }

  final app = {'key': '/apps/firefox.desktop', 'name': 'Firefox'};

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShortcutPage(core: fake, app: app))),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    calls.clear();
    available = true;
    assigned = false;
  });

  testWidgets('key map, picking a taken key, assigning, removing', (tester) async {
    await open(tester);
    expect(find.text('Shortcuts for Firefox'), findsOneWidget);
    expect(find.text('Opens Firefox · GNOME default “Switch to application 1”'), findsOneWidget);
    // Default modifiers: Super + Shift selected, every key shown.
    expect(calls.where((c) => c['method'] == 'shortcuts.state').last['mods'], ['SUPER', 'SHIFT']);
    expect(find.text('Keys with Super + Shift'), findsOneWidget);
    expect(find.text('● GNOME default'), findsOneWidget);

    // Super + Shift + B belongs to another app: it would move.
    await tester.tap(find.byKey(const ValueKey('key-B')));
    await tester.pumpAndSettle();
    expect(find.text('Opens Chromium now. Assigning moves it to Firefox.'), findsOneWidget);
    expect(find.text('Move here'), findsOneWidget);

    // Only Super: Q is the desktop's, Rebind.
    await tester.tap(find.byKey(const ValueKey('mod-SHIFT')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c['method'] == 'shortcuts.state').last['mods'], ['SUPER']);
    await tester.tap(find.byKey(const ValueKey('key-Q')));
    await tester.pumpAndSettle();
    expect(find.textContaining("GNOME's “Close window”"), findsOneWidget);
    expect(find.text('Rebind'), findsOneWidget);

    // Super + Alt + F is free: Assign.
    await tester.tap(find.byKey(const ValueKey('mod-ALT')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('key-F')));
    await tester.pumpAndSettle();
    expect(find.text('✓ Free.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shortcut-assign')));
    await tester.pumpAndSettle();
    final set = calls.lastWhere((c) => c['method'] == 'shortcuts.set');
    expect(set['mods'], ['SUPER', 'ALT']);
    expect(set['combo_key'], 'F');
    expect(set['action'], '');
    expect(find.text('✓ Saved — Super + Alt + F opens Firefox.'), findsOneWidget);
    expect(find.text('Launcher'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove this shortcut'));
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c['method'] == 'shortcuts.remove')['combo'], {'mods': ['SUPER', 'ALT'], 'key': 'F'});
    expect(find.text('✓ Removed Super + Alt + F.'), findsOneWidget);
  });

  testWidgets('pressing a key with modifiers, the action, changing, Esc', (tester) async {
    await open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c['method'] == 'shortcuts.state').last['mods'], ['SUPER', 'ALT']);
    expect(find.text('Super'), findsWidgets);
    expect(find.text('✓ Free.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shortcut-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Private Window').last);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c['method'] == 'shortcuts.state').last['action'], 'new-private-window');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final set = calls.lastWhere((c) => c['method'] == 'shortcuts.set');
    expect([set['combo_key'], set['action']], ['P', 'new-private-window']);

    // Change the GNOME default Super + 1: the Add controls switch to it.
    await tester.tap(find.byTooltip('Change this shortcut to another key').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Super + 1 to'), findsOneWidget);
    expect(calls.where((c) => c['method'] == 'shortcuts.state').last['editing'], containsPair('external', true));
    // Esc first leaves the change, then the page.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Add a shortcut'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('no desktop to write to', (tester) async {
    available = false;
    await open(tester);
    expect(find.textContaining('Global shortcuts need GNOME, COSMIC or Omarchy'), findsOneWidget);
    expect(find.byKey(const ValueKey('shortcut-assign')), findsNothing);
  });
}
