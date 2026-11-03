/// Desktop-entry scan: launcher_core.parse_desktop_files and its helpers
/// (reference/gnome-launcher/launcher_core.py). Output maps use the Python
/// keys, so the oracle can compare them one to one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'posix.dart';
import 'shlex.dart';

/// What the scan sees of the session: home, environment, files.
final class Session {
  Session({required this.environment, String? home})
    : home = home ?? environment['HOME'] ?? '/';
  final Map<String, String> environment;
  final String home;
  String? which(String program) => whichIn(program, environment);
}

String? whichIn(String program, Map<String, String> environment) =>
    which(program, environment);

/// A desktop entry is a few KiB; anything far larger is not one.
const maxDesktopFileBytes = 256 * 1024;

String? readDesktopFile(String path, {int cap = maxDesktopFileBytes}) {
  final bytes = Posix.instance.readRegular(path, cap);
  return bytes == null ? null : utf8.decode(bytes, allowMalformed: true)
      .replaceAll('�', '');
}

List<String> desktopDirectories(Session session) {
  final env = session.environment;
  final dataHome = env['XDG_DATA_HOME']?.isNotEmpty == true
      ? env['XDG_DATA_HOME']!
      : p.join(session.home, '.local/share');
  final dirs = <String>[p.join(dataHome, 'applications')];
  final dataDirs = env['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share';
  for (final dir in dataDirs.split(':')) {
    if (dir.trim().isEmpty) continue;
    final candidate = p.join(dir.trim(), 'applications');
    if (!dirs.contains(candidate)) dirs.add(candidate);
  }
  return dirs;
}

/// Chromium-based PWAs set NoDisplay=true and name themselves by a crx_*
/// StartupWMClass or an absolute PNG icon.
bool isPwa(Map<String, String> values) {
  if ((values['StartupWMClass'] ?? '').startsWith('crx_')) return true;
  final icon = values['Icon'] ?? '';
  return icon.startsWith('/') && icon.endsWith('.png');
}

const webAppBrowsers = {
  'google-chrome': 'Chrome',
  'google-chrome-stable': 'Chrome',
  'chrome': 'Chrome',
  'chromium': 'Chromium',
  'brave': 'Brave',
  'brave-browser': 'Brave',
  'microsoft-edge': 'Edge',
  'microsoft-edge-stable': 'Edge',
  'vivaldi': 'Vivaldi',
};

/// The browser's name when the entry is a web app installed in a
/// Chromium-based browser, else null (Python returns "the browser" for an
/// unknown one: [unknown] here).
String? browserWebApp(Map app, {String unknown = 'the browser'}) {
  List<String> argv;
  try {
    argv = shlexSplit(app['exec'] as String? ?? '');
  } on FormatException {
    return null;
  }
  if (argv.isEmpty || !argv.any((a) => a.startsWith('--app-id='))) return null;
  return webAppBrowsers[p.basename(argv.first)] ?? unknown;
}

const _envFlags = {'-i', '--ignore-environment', '-0', '--null', '-v', '--debug'};
const _envWithValue = {'-u', '--unset'};
final _envAssignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=', dotAll: true);

/// The program an Exec line starts, after an env prefix; null for env forms
/// it does not know.
String? execProgram(String command) {
  List<String> parts;
  try {
    parts = shlexSplit(command);
  } on FormatException {
    return null;
  }
  var i = 0;
  if (parts.isNotEmpty && p.basename(parts.first) == 'env') {
    i = 1;
    while (i < parts.length) {
      final word = parts[i];
      if (_envFlags.contains(word) ||
          word.startsWith('--unset=') ||
          _envAssignment.hasMatch(word)) {
        i += 1;
      } else if (_envWithValue.contains(word)) {
        i += 2;
      } else if (word == '--') {
        i += 1;
        while (i < parts.length && _envAssignment.hasMatch(parts[i])) {
          i += 1;
        }
        break;
      } else if (word.startsWith('-')) {
        return null;
      } else {
        break;
      }
    }
  }
  return i < parts.length ? parts[i] : null;
}

/// An env prefix sets or clears PATH.
bool envChangesPath(String command) {
  List<String> parts;
  try {
    parts = shlexSplit(command);
  } on FormatException {
    return false;
  }
  if (parts.isEmpty || p.basename(parts.first) != 'env') return false;
  for (var i = 1; i < parts.length; i++) {
    final word = parts[i];
    if (word.startsWith('PATH=') ||
        word == '-i' ||
        word == '--ignore-environment' ||
        word == '--unset=PATH') {
      return true;
    }
    if (_envWithValue.contains(word)) {
      i++;
      if (i < parts.length && parts[i] == 'PATH') return true;
    } else if (!(_envFlags.contains(word) ||
        word == '--' ||
        word.startsWith('--unset=') ||
        _envAssignment.hasMatch(word))) {
      return false;
    }
  }
  return false;
}

bool executableExists(String command, Session session) {
  var program = execProgram(command);
  if (program != null && !program.contains('/') && envChangesPath(command)) {
    program = null;
  }
  if (program == null || program.isEmpty) {
    List<String> parts;
    try {
      parts = shlexSplit(command);
    } on FormatException {
      return false;
    }
    if (parts.isEmpty || p.basename(parts.first) != 'env' || parts.length < 2) {
      return false;
    }
    program = parts.first;
  }
  if (program.contains('\x00')) return false;
  return program.contains('/')
      ? Posix.instance.executable(program)
      : session.which(program) != null;
}

// --- GKeyFile, as far as Gio's actions need it --------------------------------

/// The groups of a key file, or null when GLib would refuse it.
Map<String, Map<String, String>>? parseKeyFile(String text) {
  final groups = <String, Map<String, String>>{};
  Map<String, String>? current;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trimLeft();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[')) {
      final end = line.indexOf(']');
      if (end < 0 || line.substring(end + 1).trim().isNotEmpty) return null;
      final name = line.substring(1, end);
      if (name.isEmpty || name.contains('[')) return null;
      current = groups.putIfAbsent(name, () => {});
      continue;
    }
    final eq = line.indexOf('=');
    if (current == null || eq <= 0) return null;
    final key = line.substring(0, eq).trimRight();
    if (key.isEmpty) return null;
    current[key] = line.substring(eq + 1).trimLeft();
  }
  return groups;
}

String _unescape(String value) => value.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => switch (m[1]) {
    's' => ' ',
    'n' => '\n',
    't' => '\t',
    'r' => '\r',
    _ => m[1]!,
  },
);

List<String> _stringList(String value) {
  final out = <String>[];
  final word = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == r'\' && i + 1 < value.length) {
      final n = value[++i];
      word.write(n == ';' ? ';' : _unescape('\\$n'));
    } else if (c == ';') {
      out.add(word.toString());
      word.clear();
    } else {
      word.write(c);
    }
  }
  if (word.isNotEmpty) out.add(word.toString());
  return out;
}

/// g_get_language_names: LANGUAGE (unless the locale is C), then the
/// first of LC_ALL, LC_MESSAGES, LANG, each with its shorter variants.
List<String> languageNames(Map<String, String> env) {
  String? locale;
  for (final key in ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
    if (env[key]?.isNotEmpty == true) {
      locale = env[key];
      break;
    }
  }
  final names = <String>[];
  final wanted = <String>[
    if (locale != null && locale != 'C' && env['LANGUAGE']?.isNotEmpty == true)
      ...env['LANGUAGE']!.split(':').where((s) => s.isNotEmpty),
    ?locale,
  ];
  for (final name in wanted) {
    final m = RegExp(r'^([^_.@]+)(_[^.@]+)?(\.[^@]+)?(@.+)?$').firstMatch(name);
    if (m == null) continue;
    final lang = m[1]!, terr = m[2] ?? '', enc = m[3] ?? '', mod = m[4] ?? '';
    for (final variant in [
      '$lang$terr$enc$mod',
      if (enc.isNotEmpty) '$lang$terr$mod',
      if (terr.isNotEmpty) '$lang$enc$mod',
      if (terr.isNotEmpty && enc.isNotEmpty) '$lang$mod',
      if (mod.isNotEmpty) '$lang$terr$enc',
      if (mod.isNotEmpty && enc.isNotEmpty) '$lang$terr',
      if (mod.isNotEmpty && terr.isNotEmpty) '$lang$enc',
      if (mod.isNotEmpty) lang,
    ]) {
      if (variant != 'C' && !names.contains(variant)) names.add(variant);
    }
  }
  return names;
}

String? localeString(Map<String, String> group, String key, List<String> langs) {
  for (final lang in langs) {
    final value = group['$key[$lang]'];
    if (value != null) return _unescape(value);
  }
  final plain = group[key];
  return plain == null ? null : _unescape(plain);
}

/// The entry's own actions, as Gio lists them (empty when Gio would not load
/// the file as an application).
List<Map<String, String>> desktopActions(
  String text,
  Map<String, String> actionExecs,
  Session session,
) {
  final groups = parseKeyFile(text);
  final entry = groups?['Desktop Entry'];
  if (groups == null || entry == null || entry['Type'] != 'Application') {
    return [];
  }
  final tryExec = entry['TryExec'];
  if (tryExec != null && tryExec.isNotEmpty) {
    final program = _unescape(tryExec);
    if (!(program.startsWith('/')
        ? Posix.instance.executable(program)
        : session.which(program) != null)) {
      return [];
    }
  }
  final langs = languageNames(session.environment);
  return [
    for (final id in _stringList(entry['Actions'] ?? ''))
      {
        'id': id,
        'name':
            localeString(groups['Desktop Action $id'] ?? {}, 'Name', langs) ??
            'Unnamed',
        'exec': actionExecs[id] ?? '',
      },
  ];
}

bool _true(String? value) {
  final v = (value ?? '').trim().toLowerCase();
  return v == 'true' || v == '1';
}

String _strip(String text, String chars) {
  var start = 0, end = text.length;
  while (start < end && chars.contains(text[start])) {
    start++;
  }
  while (end > start && chars.contains(text[end - 1])) {
    end--;
  }
  return text.substring(start, end);
}

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// The desktop-file part of parse_desktop_files: entries in XDG order, the
/// first id and the first name winning. [seenNames] collects the names.
List<Map<String, dynamic>> scanDesktopEntries(
  Session session,
  Set<String> seenNames,
) {
  final apps = <Map<String, dynamic>>[];
  final seenIds = <String>{};
  for (final directory in desktopDirectories(session)) {
    if (!FileSystemEntity.isDirectorySync(directory)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(directory).listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final entity in entries) {
      final path = entity.path;
      final id = p.basename(path);
      if (!id.endsWith('.desktop') || id == '.desktop') continue;
      if (!seenIds.add(id)) continue;
      final text = readDesktopFile(path);
      if (text == null) continue;
      final values = <String, String>{}, actionExecs = <String, String>{};
      String? section;
      for (final raw in const LineSplitter().convert(text)) {
        final line = raw.trim();
        if (line.startsWith('[')) {
          section = _strip(line, '[]');
        } else if (section == 'Desktop Entry' && line.contains('=')) {
          final eq = line.indexOf('=');
          values[line.substring(0, eq)] = line.substring(eq + 1);
        } else if ((section ?? '').startsWith('Desktop Action ') &&
            line.startsWith('Exec=')) {
          actionExecs[section!.substring('Desktop Action '.length)] = line
              .substring(5);
        }
      }
      final name = values['Name'], command = values['Exec'];
      if (name == null || name.isEmpty || command == null || command.isEmpty) {
        continue;
      }
      final tryExec = values['TryExec'];
      if (tryExec != null &&
          tryExec.isNotEmpty &&
          !executableExists(tryExec, session)) {
        continue;
      }
      if (!executableExists(command, session)) continue;
      if (_true(values['NoDisplay']) && !isPwa(values)) continue;
      final nameKey = name.trim().toLowerCase();
      if (!seenNames.add(nameKey)) continue;
      apps.add({
        'name': name,
        'exec': command.replaceAll(RegExp(r'%[a-zA-Z]'), '').trim(),
        'icon': values['Icon'] ?? '',
        'desktop_path': path,
        'actions': desktopActions(text, actionExecs, session),
        'description': (values['Comment'] ?? '').trim(),
        'terminal': _true(values['Terminal']),
        'sandboxed':
            (values['X-Flatpak'] ?? '').isNotEmpty ||
            (values['X-SnapInstanceName'] ?? '').isNotEmpty,
        'pwa': isPwa(values),
        'categories': (values['Categories'] ?? '')
            .split(';')
            .where((c) => c.isNotEmpty)
            .take(20)
            .toList(),
        'desktop_id': _stem(id),
        'startup_class': values['StartupWMClass'] ?? '',
      });
    }
  }
  return apps;
}
