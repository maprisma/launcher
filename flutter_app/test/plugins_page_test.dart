import 'package:maprisma_launcher/plugins_page.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('plugins: sections, out of the bar, removal that would lose work', (tester) async {
    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final asked = <Map<String, dynamic>>[];
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async {
      asked.add({'method': method, ...params});
      return switch (method) {
        'plugins.list' => {
          'plugins': [
            {'plugin_id': 'a.hue', 'name': 'Hue Lights', 'bar_widget': true, 'in_bar': true, 'openable': true, 'removable': true},
            {'plugin_id': 'a.wlan', 'name': 'WLAN', 'bar_widget': true, 'in_bar': false, 'openable': false, 'removable': true},
            {'plugin_id': 'omarchy.launcher', 'name': 'Launcher', 'bar_widget': false, 'openable': true},
          ],
        },
        'plugins.updates' => {'behind': {'a.hue': 2}},
        'plugins.remove_plan' => {'note': 'loses', 'loses_work': true, 'changed': 3, 'ahead': 0},
        _ => <String, dynamic>{},
      };
    }

    await tester.pumpWidget(MaterialApp(home: PluginsPage(core: fake)));
    await tester.pumpAndSettle();
    expect(find.text('In the bar'), findsOneWidget);
    expect(find.text('Not in the bar'), findsOneWidget);
    expect(find.text('Panels and overlays'), findsOneWidget);
    expect(find.byTooltip('2 new commits'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('Hue Lights')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take out of the bar'));
    await tester.pumpAndSettle();
    expect(asked.where((a) => a['method'] == 'plugins.bar').single, containsPair('placed', false));

    await tester.tapAt(tester.getCenter(find.text('WLAN')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall…'));
    await tester.pumpAndSettle();
    expect(find.text('The folder is deleted, including 3 changed files.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(asked.where((a) => a['method'] == 'plugins.remove'), isEmpty);
  });
}
