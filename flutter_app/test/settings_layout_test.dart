import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/settings_page.dart';

/// Settings: sections on the left, the chosen one's rows on the right, and
/// Find in Settings over all of them.
void main() {
  Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async =>
      method == 'packages.managers' ? <String, dynamic>{'managers': []} : <String, dynamic>{};

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(core: core, settings: const {'language': 'auto'}, onChanged: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-general')));
    await tester.pumpAndSettle();
  }

  testWidgets('a section shows only its own rows, with what they do', (tester) async {
    await mount(tester);
    for (final id in ['general', 'layout', 'sizes', 'apps', 'screenshots']) {
      expect(find.byKey(ValueKey('settings-section-$id')), findsOneWidget, reason: id);
    }
    expect(find.byKey(const ValueKey('settings-reset')), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.byKey(const ValueKey('view-buttons')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-section-layout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('view-buttons')), findsOneWidget);
    expect(find.text('Language'), findsNothing);
    // The explanation is under the name, not only in its tooltip.
    expect(find.textContaining('Corners of the window'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('settings-section-layout'))).selected, isTrue);
  });

  testWidgets('Find in Settings shows the matching rows of every section', (tester) async {
    await mount(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-find')), 'screenshot');
    await tester.pumpAndSettle();
    // From General: the rows of Screenshots, under its name.
    expect(find.byKey(const ValueKey('screenshot-key')), findsOneWidget);
    expect(find.text('Language'), findsNothing);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('settings-section-general'))).selected, isFalse);

    await tester.enterText(find.byKey(const ValueKey('settings-find')), 'zzz-nothing');
    await tester.pumpAndSettle();
    expect(find.text('No setting matches “zzz-nothing”'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
  });
}
