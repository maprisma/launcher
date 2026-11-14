import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/install_page.dart';

void main() {
  testWidgets('local downloads label and review install without a terminal', (tester) async {
    final calls = <String>[];
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      calls.add(method);
      return switch (method) {
        'packages.managers' => {'managers': []},
        'packages.search' => {'results': [
          {'manager': 'local', 'package': 'TaskManager.AppImage', 'name': 'TaskManager',
           'installable': true, 'description': 'TaskManager.AppImage'},
        ]},
        'packages.install_plan' => {'local': true, 'command': '/Downloads/TaskManager.AppImage\n3 bytes\nSHA-256: abc\n→ /Applications/TaskManager.AppImage'},
        _ => {},
      };
    }
    await tester.pumpWidget(MaterialApp(home: InstallPage(core: core)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TaskManager');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('AppImage in Downloads'), findsOneWidget);
    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SHA-256: abc'), findsOneWidget);
    expect(find.text('A terminal runs this and asks for your password:'), findsNothing);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(calls, contains('packages.install'));
    expect(calls.where((c) => c.startsWith('terminal.')), isEmpty);
  });
  testWidgets('manual search shows GitHub repositories and source failures honestly', (tester) async {
    final calls = <String>[];
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      calls.add(method);
      return switch (method) {
        'packages.managers' => {'managers': []},
        'packages.search' => {'github_unavailable': true, 'results': [
          {'manager': 'github', 'package': 'example/pdf-craft', 'repository': 'https://github.com/example/pdf-craft',
            'installable': false, 'description': 'PDF tools'},
        ]},
        _ => {},
      };
    }
    await tester.pumpWidget(MaterialApp(home: InstallPage(core: core)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Searches: GitHub'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'pdf craft');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('GitHub search is unavailable. Package results are still shown.'), findsOneWidget);
    expect(find.text('Install…'), findsNothing);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(calls, contains('open.url'));
    expect(calls, isNot(contains('packages.install_plan')));
  });
}
