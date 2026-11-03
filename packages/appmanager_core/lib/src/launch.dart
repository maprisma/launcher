/// Starting apps and their actions without Gio: the Exec line as Gio's
/// expand_application_parameters + g_shell_parse_argv read it.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';

/// g_shell_quote: one single-quoted word.
String gShellQuote(String word) => "'${word.replaceAll("'", r"'\''")}'";

/// g_shell_parse_argv: blanks split; '…' literal; "…" where a backslash
/// escapes only $ ` " \ and a newline; outside quotes a backslash escapes
/// anything (backslash-newline vanishes); # starts a comment at a word's start.
List<String>? gShellParse(String text) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == ' ' || c == '\t' || c == '\n') {
      if (inWord) {
        words.add(word.toString());
        word.clear();
        inWord = false;
      }
      i++;
    } else if (c == '#' && !inWord) {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
    } else if (c == "'") {
      final end = text.indexOf("'", i + 1);
      if (end < 0) return null;
      word.write(text.substring(i + 1, end));
      inWord = true;
      i = end + 1;
    } else if (c == '"') {
      i++;
      var closed = false;
      while (i < text.length) {
        final d = text[i];
        if (d == '"') {
          closed = true;
          i++;
          break;
        }
        if (d == r'\' && i + 1 < text.length && r'$`"\'.contains(text[i + 1])) {
          word.write(text[i + 1]);
          i += 2;
        } else if (d == r'\' && i + 1 < text.length && text[i + 1] == '\n') {
          i += 2;
        } else {
          word.write(d);
          i++;
        }
      }
      if (!closed) return null;
      inWord = true;
    } else if (c == r'\') {
      if (i + 1 >= text.length) return null;
      if (text[i + 1] != '\n') word.write(text[i + 1]);
      inWord = true;
      i += 2;
    } else {
      word.write(c);
      inWord = true;
      i++;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

/// The argv of an Exec line (key-file escapes already undone), with no
/// files: %f %F %u %U and the deprecated codes vanish, %i is `--icon <icon>`,
/// %c the name, %k the desktop file, %% a percent sign.
List<String>? execArgv(
  String exec, {
  String icon = '',
  String name = '',
  String desktopFile = '',
}) {
  final out = StringBuffer();
  for (var i = 0; i < exec.length; i++) {
    final c = exec[i];
    if (c != '%' || i + 1 >= exec.length) {
      out.write(c);
      continue;
    }
    final code = exec[++i];
    switch (code) {
      case '%':
        out.write('%');
      case 'i':
        if (icon.isNotEmpty) out.write('--icon ${gShellQuote(icon)}');
      case 'c':
        out.write(gShellQuote(name));
      case 'k':
        if (desktopFile.isNotEmpty) out.write(gShellQuote(desktopFile));
      default:
        break; // %f %F %u %U %d %D %n %N %v %m: nothing to hand over.
    }
  }
  final argv = gShellParse(out.toString());
  return argv == null || argv.isEmpty ? null : argv;
}

const terminals = [
  ('xdg-terminal-exec', <String>[]),
  ('ptyxis', ['--']),
  ('kgx', ['--']),
  ('gnome-terminal', ['--']),
  ('cosmic-term', ['--']),
  ('konsole', ['-e']),
  ('xfce4-terminal', ['-x']),
  ('ghostty', ['-e']),
  ('foot', <String>[]),
  ('alacritty', ['-e']),
  ('kitty', <String>[]),
  ('wezterm', ['start', '--']),
  ('xterm', ['-e']),
];

/// A terminal to run a command in: $TERMINAL when it is a plain program
/// name, else the first known one installed (argv prefix).
List<String>? defaultTerminal(Session session) {
  final own = session.environment['TERMINAL'] ?? '';
  if (RegExp(r'^[A-Za-z0-9._+-]{1,64}$').hasMatch(own)) {
    final found = session.which(own);
    if (found != null) {
      final known = terminals.where((t) => t.$1 == own).firstOrNull;
      return [found, ...known?.$2 ?? ['-e']];
    }
  }
  for (final (program, follow) in terminals) {
    final found = session.which(program);
    if (found != null) return [found, ...follow];
  }
  return null;
}

Future<bool> startDetached(
  List<String> argv,
  Session session, {
  String? workingDirectory,
  Map<String, String> extra = const {},
}) async {
  try {
    await Process.start(
      argv.first,
      argv.sublist(1),
      mode: ProcessStartMode.detached,
      workingDirectory: workingDirectory ?? session.home,
      environment: {...session.environment, ...extra},
      includeParentEnvironment: false,
    );
    return true;
  } on ProcessException {
    return false;
  }
}

/// What the desktop file says about starting it (or one of its actions).
({List<String> argv, bool terminal, String? cwd})? desktopCommand(
  String path,
  Session session, {
  String? action,
}) {
  final text = readDesktopFile(path);
  final groups = text == null ? null : parseKeyFile(text);
  final entry = groups?['Desktop Entry'];
  if (groups == null || entry == null) return null;
  final langs = languageNames(session.environment);
  final group = action == null ? entry : groups['Desktop Action $action'];
  if (group == null) return null;
  if (action != null &&
      !(localeString(entry, 'Actions', const []) ?? '').split(';').contains(action)) {
    return null;
  }
  final exec = localeString(group, 'Exec', const []);
  if (exec == null || exec.isEmpty) return null;
  final argv = execArgv(
    exec,
    icon: localeString(entry, 'Icon', const []) ?? '',
    name: localeString(entry, 'Name', langs) ?? '',
    desktopFile: path,
  );
  if (argv == null) return null;
  final cwd = localeString(entry, 'Path', const []);
  final term = (entry['Terminal'] ?? '').trim().toLowerCase();
  return (
    argv: argv,
    terminal: term == 'true' || term == '1',
    cwd: cwd != null && cwd.isNotEmpty && Directory(cwd).existsSync() ? cwd : null,
  );
}

/// launcher_core.launch_app: argv entries (AppImages, CLI tools) start as
/// they are; desktop entries by their Exec line. Exec is never handed to a
/// shell.
Future<bool> launchApp(
  Map app,
  Session session, {
  List<String>? terminal,
  String? action,
}) async {
  final argv = app['argv'];
  if (argv is List && argv.isNotEmpty && action == null) {
    return startDetached([for (final a in argv) '$a'], session);
  }
  final path = app['desktop_path'] as String? ?? '';
  if (path.isEmpty) return false;
  final command = desktopCommand(path, session, action: action);
  if (command == null) return false;
  var run = command.argv;
  if (command.terminal) {
    if (terminal == null) return false;
    run = [...terminal, ...run];
  }
  return startDetached(
    run,
    session,
    workingDirectory: command.cwd,
    extra: {'GIO_LAUNCHED_DESKTOP_FILE': p.absolute(path)},
  );
}
