import 'dart:io';

import 'package:maprisma_launcher_core/src/keyboard_layout.dart';
import 'package:maprisma_launcher_core/src/shortcuts.dart';
import 'package:maprisma_launcher_core/src/shortcuts_kde.dart';
import 'package:test/test.dart';

void main() {
  test('German rows are QWERTZ with the German keys', () {
    final de = keyRowsFor('de');
    expect(de[1].take(6), ['Q', 'W', 'E', 'R', 'T', 'Z']);
    expect(de[3].take(2), ['less', 'Y']);
    expect(keyRowsFor('fr'), same(usKeyRows));
    for (final k in ['ssharp', 'udiaeresis', 'odiaeresis', 'adiaeresis', 'plus', 'numbersign', 'less', 'bracketleft']) {
      expect(keyMapKeys, contains(k));
    }
    expect(keyLabel('udiaeresis'), 'Ü');
    expect(keyLabel('numbersign'), '#');
  });

  test('German keys round-trip through KDE key codes', () {
    for (final k in ['ssharp', 'udiaeresis', 'odiaeresis', 'adiaeresis', 'plus', 'numbersign', 'less']) {
      final accel = accelerator(makeCombo(['SUPER'], k)!);
      final code = acceleratorToQt(accel);
      expect(code, isNotNull, reason: k);
      expect(qtToAccelerator(code!), accel, reason: k);
    }
  });

  test('the layout comes from Plasma, then COSMIC', () {
    final home = Directory.systemTemp.createTempSync('kbd');
    addTearDown(() => home.deleteSync(recursive: true));
    final env = {'HOME': home.path};
    File('${home.path}/.config/cosmic/com.system76.CosmicComp/v1/xkb_config')
      ..createSync(recursive: true)
      ..writeAsStringSync('(\n    layout: "fr",\n)');
    expect(detectKeyboardLayout(env), 'fr');
    File('${home.path}/.config/kxkbrc').writeAsStringSync('[Layout]\nLayoutList=de,us\nUse=true\n');
    expect(detectKeyboardLayout(env), 'de');
  });
}
