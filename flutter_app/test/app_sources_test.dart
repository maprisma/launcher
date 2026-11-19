import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/settings_page.dart';

/// Settings › App sources: GitHub is a chip next to the package managers;
/// it switches github_source, the others the package_managers list.
void main() {
  testWidgets('App sources: the GitHub chip switches github_source, pacman the managers list', (tester) async {
    final sets = <(String, Object?)>[];
    var github = true;
    var managers = ['pacman', 'flatpak'];
    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'settings.set') {
        sets.add((params['key'] as String, params['value']));
        if (params['key'] == 'github_source') github = params['value'] as bool;
        if (params['key'] == 'package_managers') managers = (params['value'] as List).cast<String>();
        return {'language': 'auto', 'github_source': github};
      }
      return switch (method) {
        'packages.managers' => <String, dynamic>{
          'managers': [
            {'id': 'pacman', 'label': 'pacman', 'program': 'pacman', 'enabled': managers.contains('pacman')},
            {'id': 'flatpak', 'label': 'Flatpak', 'program': 'flatpak', 'enabled': managers.contains('flatpak')},
            {'id': 'github', 'label': 'GitHub', 'program': '', 'enabled': github},
          ],
        },
        _ => <String, dynamic>{},
      };
    }

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(core: core, settings: const {'language': 'auto'}, onChanged: (_) {}, popupPossible: false),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'App sources');
    await tester.pumpAndSettle();
    expect(find.text('App sources'), findsWidgets);
    final chip = find.widgetWithText(FilterChip, 'GitHub');
    expect(tester.widget<FilterChip>(chip).selected, isTrue);

    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(sets.last, ('github_source', false));
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'GitHub')).selected, isFalse);

    // A package manager chip never puts "github" into package_managers.
    await tester.tap(find.widgetWithText(FilterChip, 'Flatpak'));
    await tester.pumpAndSettle();
    expect(sets.last.$1, 'package_managers');
    expect(sets.last.$2, ['pacman']);
  });
}
