/// The app's terminal page against a fake core: output, keys, the end, and
/// the outside terminal when this system has none.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/backend.dart';
import 'package:maprisma_launcher/terminal_page.dart';

void main() {
  testWidgets('output shows, keys go to the core, Back only after the end, then the exit code', (tester) async {
    final written = <int>[];
    final reads = <String>['[sudo] password for uwe: '];
    var ended = false;
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async => switch (method) {
      'term.start' => {'id': 't1', 'command': 'sudo pacman -S -- gimp'},
      'term.write' => (() {
        written.addAll(base64Decode(params['data'] as String));
        return {'accepted': base64Decode(params['data'] as String).length, 'ended': false};
      })(),
      'term.read' => {
        'data': base64Encode(utf8.encode(reads.isEmpty ? '' : reads.removeAt(0))),
        'ended': ended,
        'code': ended ? 0 : null,
      },
      _ => <String, dynamic>{},
    };
    int? result = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await runInTerminal(context, core, const {'action': 'install'}, 'Installing GIMP…'),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Installing GIMP…'), findsOneWidget);
    expect(find.text('sudo pacman -S -- gimp'), findsOneWidget);
    expect(TerminalPage.running.value, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Running…'), findsOneWidget);
    // Back is off while it runs; the keys reach the program.
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Back')).onPressed, isNull);
    tester.testTextInput.enterText('x');
    await tester.pump(const Duration(milliseconds: 60));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(utf8.decode(written), 'x\r');

    ended = true;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Done.'), findsOneWidget);
    expect(TerminalPage.running.value, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(result, 0);
  });

  testWidgets('no terminal here: the outside way, at once', (tester) async {
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async =>
        method == 'term.start' ? throw ServiceError('no_pty') : <String, dynamic>{};
    var outside = 0;
    int? result = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await runInTerminal(
              context,
              core,
              const {'action': 'system'},
              'System update',
              outside: () async => outside++,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(outside, 1);
    expect(result, isNull);
    expect(find.text('go'), findsOneWidget);
    expect(TerminalPage.running.value, 0);
  });
}
