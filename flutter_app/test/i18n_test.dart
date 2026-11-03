import 'dart:io';

import 'package:appmanager/i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('every interface text is translated and the files are up to date', () {
    final repo = p.normalize(p.join(Directory.current.path, '..'));
    final result = Process.runSync('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/i18n.py'), '--check']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('system language and plurals as i18n.py', () {
    expect(systemLanguage({'LANG': 'de_DE.UTF-8'}), 'de');
    expect(systemLanguage({'LC_ALL': 'C', 'LANG': 'fr_FR'}), 'fr');
    expect(systemLanguage({'LANG': 'ja_JP.UTF-8'}), 'en');
    expect(systemLanguage({}), 'en');
    I18n.useTable('pl', {'\x04{0} app': ['{0} aplikacja', '{0} aplikacje', '{0} aplikacji']});
    expect([for (final n in [1, 2, 5, 12, 22, 25]) trn('{0} app', '{0} apps', n)], [
      '1 aplikacja', '2 aplikacje', '5 aplikacji', '12 aplikacji', '22 aplikacje', '25 aplikacji',
    ]);
    I18n.useTable('en', const {});
    expect(trn('{0} app', '{0} apps', 1), '1 app');
    expect(trf('Move {0} to', ['X']), 'Move X to');
  });
}
