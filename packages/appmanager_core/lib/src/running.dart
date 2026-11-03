/// Which apps run: the user's processes by name (launcher_core
/// background_process_names, app_process_name, terminal_command).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'posix.dart';
import 'shlex.dart';

const terminalPrograms = {
  'foot', 'footclient', 'alacritty', 'kitty', 'ghostty', 'wezterm', 'xterm',
  'ptyxis', 'kgx', 'gnome-terminal', 'gnome-terminal-server', 'konsole',
};
const _shared = {'sh', 'bash', 'env', 'flatpak', 'gtk-launch', 'python', 'python3', 'java'};

/// For a terminal launcher like `foot -e /path/claude`: the command's name.
String? terminalCommand(Map app) {
  List<String> args;
  try {
    args = shlexSplit(app['exec'] as String? ?? '');
  } on FormatException {
    return null;
  }
  if (args.isEmpty) return null;
  final first = p.basename(args.first).toLowerCase();
  if (!terminalPrograms.contains(first) && first != 'xdg-terminal-exec') return null;
  for (final flag in ['-e', '--command', '--']) {
    final i = args.indexOf(flag);
    if (i >= 0) return i + 1 < args.length ? p.basename(args[i + 1]).toLowerCase() : null;
  }
  return null;
}

/// The process name an app runs as, or null when it cannot be told.
String? appProcessName(Map app) {
  List<String> args;
  try {
    args = shlexSplit(app['exec'] as String? ?? '');
  } on FormatException {
    return null;
  }
  var i = 0;
  if (args.isNotEmpty && p.basename(args.first) == 'env') {
    i = 1;
    while (i < args.length && args[i].contains('=') && !args[i].startsWith('-')) {
      i++;
    }
  }
  if (i >= args.length) return null;
  final name = p.basename(args[i]).toLowerCase();
  if (_shared.contains(name)) return null;
  if (name == 'xdg-terminal-exec' ||
      (terminalPrograms.contains(name) && (args.contains('-e') || args.contains('--command')))) {
    return null;
  }
  return name;
}

/// The user's processes: the executable's name and the first two words of
/// the command line (scripts and node tools count by their own name).
/// Also how many processes each executable name has (for terminals).
(Set<String>, Map<String, int>) processNames({String proc = '/proc'}) {
  final names = <String>{};
  final exes = <String, int>{};
  final uid = Posix.instance.uid;
  List<FileSystemEntity> entries;
  try {
    entries = Directory(proc).listSync(followLinks: false);
  } on FileSystemException {
    return (names, exes);
  }
  for (final entry in entries) {
    final pid = p.basename(entry.path);
    if (!RegExp(r'^\d+$').hasMatch(pid)) continue;
    if (Posix.instance.ownerOf(entry.path) != uid) continue;
    try {
      final exe = p.basename(Link(p.join(entry.path, 'exe')).targetSync()).toLowerCase();
      names.add(exe);
      exes[exe] = (exes[exe] ?? 0) + 1;
      final file = File(p.join(entry.path, 'cmdline')).openSync();
      List<int> head;
      try {
        head = file.readSync(4096);
      } finally {
        file.closeSync();
      }
      final parts = head.isEmpty ? <List<int>>[] : _split(head);
      for (final arg in parts.take(2)) {
        if (arg.isNotEmpty) names.add(p.basename(utf8.decode(arg, allowMalformed: true)).toLowerCase());
      }
    } on FileSystemException {
      continue;
    }
  }
  return (names, exes);
}

List<List<int>> _split(List<int> bytes) {
  final out = <List<int>>[];
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0) {
      out.add(bytes.sublist(start, i));
      start = i + 1;
    }
  }
  if (start < bytes.length) out.add(bytes.sublist(start));
  return out;
}

/// The keys of the apps that run. A terminal counts only when it was
/// opened itself, not only as the window of a command-line app.
Set<String> runningApps(Map<String, Map> apps, Set<String> names, Map<String, int> exes) {
  final commands = {for (final app in apps.values) ?terminalCommand(app)};
  final commandRuns = commands.any(names.contains);
  final out = <String>{};
  for (final e in apps.entries) {
    final name = terminalCommand(e.value) ?? appProcessName(e.value);
    if (name == null || !names.contains(name)) continue;
    if (terminalPrograms.contains(name) && (commandRuns || (exes[name] ?? 0) == 0)) continue;
    out.add(e.key);
  }
  return out;
}
