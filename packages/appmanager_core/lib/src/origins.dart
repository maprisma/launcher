/// Where an app comes from, for the "by origin" view: the user's default
/// apps (mimeapps.list, xdg-terminals.list) and, per desktop, the rest
/// (details.origin_section in both references).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';
import 'shlex.dart';

const maxListBytes = 256 * 1024;

const roleMimes = [
  ('browser', ['x-scheme-handler/http', 'x-scheme-handler/https', 'text/html']),
  ('email', ['x-scheme-handler/mailto']),
  ('files', ['inode/directory']),
  ('editor', ['text/plain']),
  ('images', ['image/png', 'image/jpeg']),
  ('video', ['video/mp4', 'video/x-matroska']),
  ('music', ['audio/mpeg', 'audio/flac']),
  ('pdf', ['application/pdf']),
];

List<String> _readLines(String path) {
  try {
    final file = File(path).openSync();
    try {
      return const LineSplitter().convert(
        utf8.decode(file.readSync(maxListBytes), allowMalformed: true),
      );
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return const [];
  }
}

String configHome(Session session) =>
    session.environment['XDG_CONFIG_HOME']?.isNotEmpty == true
    ? session.environment['XDG_CONFIG_HOME']!
    : p.join(session.home, '.config');

/// mime → the first default desktop id (the first file naming a type wins).
Map<String, String> mimeDefaults(Session session) {
  final config = configHome(session);
  final found = <String, String>{};
  for (final path in [
    p.join(config, 'gnome-mimeapps.list'),
    p.join(config, 'mimeapps.list'),
    p.join(session.home, '.local/share/applications/mimeapps.list'),
  ]) {
    String? section;
    for (final raw in _readLines(path)) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        section = line;
      } else if (section == '[Default Applications]' && line.contains('=')) {
        final eq = line.indexOf('=');
        final first = line
            .substring(eq + 1)
            .split(';')
            .firstWhere((i) => i.trim().isNotEmpty, orElse: () => '');
        found.putIfAbsent(line.substring(0, eq).trim(), () => first.trim());
      }
    }
  }
  return found;
}

/// xdg-terminal-exec's lists: the desktop's own (XDG_CURRENT_DESKTOP,
/// lower case), the general one, then [shipped] (a desktop's default list).
List<String> terminalLists(Session session, {List<String> shipped = const []}) {
  final config = configHome(session);
  final desktops = (session.environment['XDG_CURRENT_DESKTOP'] ?? '')
      .toLowerCase()
      .split(':')
      .where((d) => RegExp(r'^[a-z0-9_-]{1,40}$').hasMatch(d));
  return [
    for (final d in desktops) p.join(config, '$d-xdg-terminals.list'),
    p.join(config, 'xdg-terminals.list'),
    ...shipped,
  ];
}

/// The first terminal entry of those lists, or null.
String? defaultTerminalEntry(Session session, {List<String>? lists}) {
  for (final path in lists ?? terminalLists(session)) {
    for (final raw in _readLines(path)) {
      final line = raw.trim();
      if (line.isNotEmpty && !line.startsWith('#')) return line;
    }
  }
  return null;
}

Set<String> defaultDesktops(Session session, {List<String>? lists}) {
  final defaults = mimeDefaults(session);
  final found = <String>{
    for (final (_, mimes) in roleMimes)
      for (final m in mimes)
        if (defaults[m]?.isNotEmpty == true) defaults[m]!,
  };
  final terminal = defaultTerminalEntry(session, lists: lists);
  return terminal == null ? found : {...found, terminal};
}

/// The roles an app is the default app for.
List<String> defaultRoles(Map app, Session session, {List<String>? lists}) {
  final desktop = p.basename(app['desktop_path'] as String? ?? '');
  if (desktop.isEmpty) return [];
  final defaults = mimeDefaults(session);
  final roles = [
    for (final (role, mimes) in roleMimes)
      if (mimes.any((m) => defaults[m] == desktop)) role,
  ];
  if (defaultTerminalEntry(session, lists: lists) == desktop) {
    roles.insert(roles.isNotEmpty && roles.first == 'browser' ? 1 : 0, 'terminal');
  }
  return roles;
}

/// details.command_argv: the command without leading env VAR=x.
List<String> commandArgv(Map app) {
  final argv = app['argv'];
  if (argv is List && argv.isNotEmpty) return [for (final a in argv) '$a'];
  List<String> words;
  try {
    words = shlexSplit(app['exec'] as String? ?? '');
  } on FormatException {
    return [];
  }
  if (words.isNotEmpty && p.basename(words.first) == 'env') {
    words = words.sublist(1);
    while (words.isNotEmpty && (words.first.contains('=') || words.first.startsWith('-'))) {
      words = words.sublist(1);
    }
  }
  return words;
}

String? webAddress(Map app) {
  final argv = commandArgv(app);
  if (argv.length > 1 &&
      p.basename(argv.first) == 'xdg-open' &&
      RegExp(r'^https?://').hasMatch(argv[1])) {
    return argv[1];
  }
  return null;
}

const terminalNames = {
  'foot', 'footclient', 'alacritty', 'kitty', 'ghostty', 'wezterm', 'xterm',
  'ptyxis', 'kgx', 'gnome-terminal', 'gnome-terminal-server', 'konsole',
};
const shells = {'sh', 'bash', 'zsh', 'fish', 'dash'};

String? terminalProgram(List<String> argv) {
  if (argv.isEmpty) return null;
  final name = p.basename(argv.first).toLowerCase();
  if (!terminalNames.contains(name) && name != 'xdg-terminal-exec') return null;
  for (final flag in ['-e', '--command', '--']) {
    final i = argv.indexOf(flag);
    if (i >= 0) {
      final rest = argv.sublist(i + 1);
      return rest.isNotEmpty && !shells.contains(p.basename(rest.first)) ? rest.first : null;
    }
  }
  return null;
}

/// The program a desktop entry runs, as an absolute real path.
String? programPath(Map app, Session session) {
  final argv = commandArgv(app);
  if (argv.isEmpty) return null;
  final program = terminalProgram(argv) ?? argv.first;
  final found = program.contains('/') ? program : session.which(program);
  if (found == null) return null;
  try {
    final path = File(found).resolveSymbolicLinksSync();
    return p.isAbsolute(path) && FileSystemEntity.isFileSync(path) ? path : null;
  } on FileSystemException {
    return null;
  }
}

/// gnome-launcher: defaults, flatpak (or Snap), user (in your home, AppImages,
/// web apps, CLI tools) or system.
String genericOrigin(Map app, Set<String> defaults, Session session) {
  final desktopPath = app['desktop_path'] as String? ?? '';
  final desktop = p.basename(desktopPath);
  if (desktop.isNotEmpty && defaults.contains(desktop)) return 'defaults';
  if (app['sandboxed'] == true ||
      desktopPath.contains('/flatpak/') ||
      desktopPath.contains('/snapd/')) {
    return 'flatpak';
  }
  if (desktopPath.isEmpty || app['pwa'] == true || webAddress(app) != null) return 'user';
  final env = session.environment;
  final userData = env['XDG_DATA_HOME']?.isNotEmpty == true
      ? env['XDG_DATA_HOME']!
      : p.join(session.home, '.local/share');
  try {
    final real = File(desktopPath).resolveSymbolicLinksSync();
    final base = Directory(userData).resolveSymbolicLinksSync();
    if (p.isWithin(base, real) || p.equals(base, real)) return 'user';
  } on FileSystemException {
    // Not resolvable: system.
  }
  return 'system';
}

/// What came with Omarchy: desktop files and programs of the packages it
/// installs or offers (pacman's local database), cached by their stamps.
final class OmarchyIndex {
  OmarchyIndex(this.session);
  final Session session;
  String get root => session.environment['OMARCHY_PATH']?.isNotEmpty == true
      ? session.environment['OMARCHY_PATH']!
      : '/usr/share/omarchy';
  static const db = '/var/lib/pacman/local';
  static const filesLimit = 16 * 1024 * 1024;
  String? _key;
  (Set<String>, Set<String>) _index = (const {}, const {});

  Set<String> _names(String file) => {
    for (final line in _readLines(p.join(root, 'install', file)))
      if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#')) line.trim(),
  };

  (Set<String>, Set<String>) get index {
    String? key;
    try {
      key =
          '${Directory(db).statSync().modified.microsecondsSinceEpoch}:'
          '${File(p.join(root, 'install/omarchy-base.packages')).statSync().modified.microsecondsSinceEpoch}';
    } on FileSystemException {
      key = null;
    }
    if (key != null && key == _key) return _index;
    final names = {..._names('omarchy-base.packages'), ..._names('omarchy-other.packages')};
    final desktops = <String>{}, programs = <String>{};
    List<FileSystemEntity> entries;
    try {
      entries = Directory(db).listSync();
    } on FileSystemException {
      entries = [];
    }
    for (final dir in entries) {
      final parts = p.basename(dir.path).split('-');
      if (parts.length < 3 || !names.contains(parts.sublist(0, parts.length - 2).join('-'))) {
        continue;
      }
      // The first filesLimit bytes, as the reference reads them.
      List<int> bytes;
      try {
        final file = File(p.join(dir.path, 'files')).openSync();
        try {
          bytes = file.readSync(filesLimit);
        } finally {
          file.closeSync();
        }
      } on FileSystemException {
        continue;
      }
      for (final line in const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true))) {
        if (line.startsWith('usr/share/applications/') && line.endsWith('.desktop')) {
          desktops.add(line.substring(line.lastIndexOf('/') + 1));
        } else if (line.startsWith('usr/bin/') && !line.endsWith('/')) {
          programs.add('/$line');
        }
      }
    }
    _key = key;
    return _index = (desktops, programs);
  }

  /// desktop_omarchy origin: defaults, omarchy or other.
  String origin(Map app, Set<String> defaults) {
    final desktop = p.basename(app['desktop_path'] as String? ?? '');
    if (desktop.isNotEmpty && defaults.contains(desktop)) return 'defaults';
    final (desktops, programs) = index;
    if (desktop.isNotEmpty &&
        (desktops.contains(desktop) ||
            FileSystemEntity.isFileSync(p.join(root, 'applications', desktop)))) {
      return 'omarchy';
    }
    if (webAddress(app) == null) {
      final program = programPath(app, session);
      if (program != null && programs.contains(program)) return 'omarchy';
    }
    return 'other';
  }
}
