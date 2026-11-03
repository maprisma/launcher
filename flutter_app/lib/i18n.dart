/// Interface translations, built in (assets/translations/<code>.json, made by
/// tools/i18n.py from the plugins' tables). gettext style as the plugins'
/// i18n.py: the English text is the key, values go in as {0}, {1}; anything
/// without a translation stays English. The language follows the system
/// (LC_ALL, LC_MESSAGES, LANG) unless Settings › Language picks one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const languages = [
  ('en', 'English'),
  ('de', 'Deutsch'),
  ('fr', 'Français'),
  ('es', 'Español'),
  ('it', 'Italiano'),
  ('pt', 'Português'),
  ('nl', 'Nederlands'),
  ('pl', 'Polski'),
];

/// Plural tables live under their own keys, apart from plain texts.
const pluralPrefix = '\x04';

/// i18n.system_language.
String systemLanguage([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  for (final name in ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
    final value = (env[name] ?? '').toLowerCase();
    final code = value.replaceAll('-', '_').split('_').first.split('.').first.split('@').first;
    if (code.isEmpty || code == 'c' || code == 'posix') continue;
    return languages.any((l) => l.$1 == code) ? code : 'en';
  }
  return 'en';
}

final class I18n {
  I18n._();
  static String language = 'en';
  static Map<String, Object?> _table = const {};

  /// Counts language changes: the app rebuilds on it.
  static final changed = ValueNotifier<int>(0);

  /// [setting]: "auto" (the system's) or a language code.
  static Future<void> use(String setting) async {
    final code = setting == 'auto' || !languages.any((l) => l.$1 == setting) ? systemLanguage() : setting;
    Map<String, Object?> table = const {};
    if (code != 'en') {
      try {
        table = Map<String, Object?>.from(jsonDecode(await rootBundle.loadString('assets/translations/$code.json')));
      } on Object {
        table = const {};
      }
    }
    if (code == language && mapEquals(table, _table)) return;
    language = code;
    _table = table;
    changed.value++;
  }

  @visibleForTesting
  static void useTable(String code, Map<String, Object?> table) {
    language = code;
    _table = table;
    changed.value++;
  }

  static String text(String english) {
    final value = _table[english];
    return value is String ? value : english;
  }

  /// i18n.ngettext with the plugins' plural rules (Polish has three forms).
  static String plural(String one, String other, int n) {
    final forms = _table['$pluralPrefix$one'];
    if (forms is! List || forms.isEmpty) return n == 1 ? one : other;
    final f = forms.cast<String>();
    if (language == 'pl' && f.length == 3) {
      final m10 = n % 10, m100 = n % 100;
      return n == 1 ? f[0] : (m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14) ? f[1] : f[2]);
    }
    if (language == 'fr' || language == 'pt') return n <= 1 ? f[0] : f.last;
    return n == 1 ? f[0] : f.last;
  }
}

String _fill(String text, List<Object?> values) {
  var out = text;
  for (var i = 0; i < values.length; i++) {
    out = out.replaceAll('{$i}', '${values[i]}');
  }
  return out;
}

/// The text in the interface language.
String tr(String english) => I18n.text(english);

/// With values: trf('Move {0} to', [name]).
String trf(String english, List<Object?> values) => _fill(I18n.text(english), values);

/// Plural with the count as {0}: trn('{0} entry', '{0} entries', n).
String trn(String one, String other, int n) => _fill(I18n.plural(one, other, n), [n]);
