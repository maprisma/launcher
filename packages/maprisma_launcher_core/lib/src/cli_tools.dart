/// Command-line agents and TUIs as entries that open in a terminal
/// (reference/gnome-launcher/cli_tools.py).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';
import 'posix.dart';

const maxWrapperBytes = 4096;
const maxWrappers = 400;
final _execRe = RegExp(
  r'^exec mise x "([^"\n]{1,512})" -- "([A-Za-z0-9._-]{1,64})" "\$@"$',
  multiLine: true,
);

const cliNames = {
  'claude': 'Claude Code', 'codex': 'Codex', 'copilot': 'GitHub Copilot CLI',
  'cursor-agent': 'Cursor Agent', 'opencode': 'OpenCode', 'crush': 'Crush',
  'grok': 'Grok', 'omp': 'Oh My Pi', 'muse': 'Muse', 'gemini': 'Gemini CLI',
  'pi': 'pi', 'amp': 'Amp', 'goose': 'Goose', 'aider': 'Aider',
  'qwen': 'Qwen Code', 'openclaw': 'OpenClaw', 'ghui': 'ghui', 'hunk': 'hunk',
};
const knownAgents = [
  'codex', 'claude', 'copilot', 'cursor-agent', 'opencode', 'gemini', 'crush',
  'amp', 'goose', 'aider', 'qwen', 'openclaw', 'pi',
];
const notApps = {
  'gh', 'node', 'npm', 'npx', 'bun', 'deno', 'python', 'python3', 'uv', 'go',
  'cargo', 'mise',
};

/// The English text; the UI translates it.
const cliDescription = 'Command-line tool, opens in a terminal';

List<String> installDirCandidates(String spec) {
  final base = spec.split('[').first;
  final plain = base
      .replaceAll(RegExp(r'[:/@]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final last = base.split('/').last;
  final colon = last.indexOf(':');
  final second = (colon < 0 ? last : last.substring(colon + 1)).replaceFirst(
    RegExp(r'^@+'),
    '',
  );
  final ok = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$');
  return [
    for (final n in [plain, second])
      if (ok.hasMatch(n) && !n.contains('..')) n,
  ];
}

Map<String, String> wrapperTools(String binDir) {
  final tools = <String, String>{};
  List<String> paths;
  try {
    paths =
        Directory(binDir)
            .listSync()
            .where((e) => FileSystemEntity.isFileSync(e.path))
            .map((e) => e.path)
            .toList()
          ..sort();
  } on FileSystemException {
    return tools;
  }
  for (final path in paths.take(maxWrappers)) {
    final bytes = Posix.instance.readRegular(path, maxWrapperBytes);
    if (bytes == null) continue;
    final match = _execRe.firstMatch(utf8.decode(bytes, allowMalformed: true));
    if (match != null && match[2] == p.basename(path)) {
      tools[p.basename(path)] = match[1]!;
    }
  }
  return tools;
}

String cliIconFor(String command, Session session) {
  bool has(String root, {bool apps = true}) {
    try {
      final dir = Directory(root);
      if (!dir.existsSync()) return false;
      if (!apps) {
        return dir.listSync().any((e) => p.basename(e.path).startsWith('$command.'));
      }
      for (final size in dir.listSync()) {
        final appsDir = Directory(p.join(size.path, 'apps'));
        if (appsDir.existsSync() &&
            appsDir.listSync().any((e) => p.basename(e.path).startsWith('$command.'))) {
          return true;
        }
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  if (has(p.join(session.home, '.local/share/icons/hicolor')) ||
      has('/usr/share/icons/hicolor') ||
      has('/usr/share/pixmaps', apps: false)) {
    return command;
  }
  return 'utilities-terminal';
}

List<Map<String, dynamic>> cliEntries(
  Set<String> knownCommands,
  Session session, {
  String appIdPrefix = 'com.maprisma.Launcher',
}) {
  final binDir = p.join(session.home, '.local/bin');
  final miseDir = p.join(session.home, '.local/share/mise');
  final installs = p.join(miseDir, 'installs');
  final tools = <String, String?>{...wrapperTools(binDir)};
  for (final name in knownAgents) {
    if (!tools.containsKey(name) &&
        FileSystemEntity.typeSync(p.join(miseDir, 'shims', name)) !=
            FileSystemEntityType.notFound) {
      tools[name] = name;
    }
  }
  final elsewhere = <String, String>{};
  for (final name in knownAgents) {
    final found = tools.containsKey(name) ? null : session.which(name);
    if (found != null) elsewhere[name] = found;
  }
  final all = <String, String?>{...tools, for (final n in elsewhere.keys) n: null};
  final entries = <Map<String, dynamic>>[];
  for (final command in all.keys.toList()..sort()) {
    final spec = all[command];
    if (knownCommands.contains(command) || notApps.contains(command)) continue;
    String folder, target;
    if (spec == null) {
      folder = target = elsewhere[command]!;
    } else {
      final dir = installDirCandidates(spec)
          .map((c) => p.join(installs, c))
          .where(FileSystemEntity.isDirectorySync)
          .firstOrNull;
      if (dir == null) continue;
      folder = dir;
      final wrapper = p.join(binDir, command);
      target = FileSystemEntity.typeSync(wrapper) != FileSystemEntityType.notFound
          ? wrapper
          : p.join(miseDir, 'shims', command);
    }
    final appId = '$appIdPrefix.$command';
    final argv = ['xdg-terminal-exec', '--app-id=$appId', '-e', target];
    entries.add({
      'name': cliNames[command] ?? command,
      'exec': argv.join(' '),
      'argv': argv,
      'icon': cliIconFor(command, session),
      'desktop_path': '',
      'actions': <Map<String, String>>[],
      'description': cliDescription,
      'categories': ['Development'],
      'desktop_id': 'cli:$command',
      'startup_class': appId,
      'cli_command': command,
      'installed_at': Posix.instance.birthTime(folder),
    });
  }
  return entries;
}
