/// The AI helper all Maprisma apps use: one shared choice in
/// `${XDG_CONFIG_HOME:-~/.config}/maprisma-ai/settings.json`, key `helper`:
/// `"auto"` or a helper id (`^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$`). A
/// missing file, a broken one or an invalid value means "auto". Writing keeps
/// every other key, atomically (tmp + rename), folder 0700, file 0600.
///
/// "auto": the first installed helper in the catalog's order (one that seems
/// signed in first), the local models after them. A chosen helper that isn't
/// installed falls back to auto. Maprisma Settings › AI sets the same file.
library;

import 'dart:io';
import 'dart:convert';
import 'posix.dart';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';

const aiAuto = 'auto';
const aiSettingsName = 'settings.json';
final aiHelperPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$');

/// Whether [value] may be stored as the shared choice.
bool validAiChoice(Object? value) =>
    value == aiAuto || (value is String && aiHelperPattern.hasMatch(value));

/// The shared settings folder (`maprisma-ai` in the config home).
String aiSettingsDir(Session session) {
  final config = session.environment['XDG_CONFIG_HOME'] ?? '';
  return p.join(
    config.startsWith('/') ? config : p.join(session.home, '.config'),
    'maprisma-ai',
  );
}

/// The shared choice. When the shared file does not exist yet, [legacy] (the
/// Launcher's own former `ask_helper`) is used if valid.
String readAiChoice(Session session, {Object? legacy}) {
  if (FileSystemEntity.typeSync(sharedAiFile(session), followLinks: false) ==
      FileSystemEntityType.notFound) {
    return legacy is String && validAiChoice(legacy) ? legacy : aiAuto;
  }
  final helper = readSharedObject(session)?['helper'];
  return validAiChoice(helper) ? helper as String : aiAuto;
}

/// Whether web discovery is on for all Maprisma apps: the shared file's
/// boolean `web_search`, set in Maprisma Settings › AI. Missing, invalid or no
/// file = off.
bool readAiWebSearch(Session session) {
  return readSharedObject(session)?['web_search'] == true;
}

/// Helpers with a documented web-only mode (search and fetch, no other
/// tools): only Claude Code (`--tools WebSearch,WebFetch`).
const webSearchHelpers = {'claude'};

/// Store [value] as the shared choice; other keys in the file stay.
void writeAiChoice(Session session, String value) {
  if (!validAiChoice(value)) throw ArgumentError.value(value, 'helper');
  final dir = Directory(aiSettingsDir(session))..createSync(recursive: true);
  chmodPath(dir.path, 0x1c0);
  final path = sharedAiFile(session);
  Posix.instance.withFlock(p.join(dir.path, 'settings.lock'), () {
    if (sharedFileBroken(session)) {
      throw FileSystemException(
        "the shared AI settings can't be read: not changed",
        path,
      );
    }
    final values = {...?readSharedObject(session), 'helper': value};
    final tmp = File(
      p.join(
        dir.path,
        '.settings.json.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      if (!Posix.instance.writeNewPrivate(
        tmp.path,
        utf8.encode('${const JsonEncoder.withIndent('  ').convert(values)}\n'),
      )) {
        throw FileSystemException(
          'Could not write shared AI settings',
          tmp.path,
        );
      }
      tmp.renameSync(path);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  });
}

/// The helper id to use for [choice] among [states] (helperStates' entries):
/// the chosen one when installed, else the first installed that seems signed
/// in, else the first installed; null when none is.
String? resolveAiChoice(String choice, List<Map<String, dynamic>> states) {
  final installed = [
    for (final h in states)
      if (h['installed'] == true) h,
  ];
  if (choice != aiAuto) {
    final hit = installed.where((h) => h['command'] == choice).firstOrNull;
    if (hit != null) return choice;
  }
  return ((installed.where((h) => h['signed_in'] == true).firstOrNull ??
          installed.firstOrNull)?['command'])
      as String?;
}

String sharedAiFile(Session session) =>
    p.join(aiSettingsDir(session), aiSettingsName);
Map<String, dynamic>? readSharedObject(Session session) {
  try {
    final bytes = Posix.instance.readRegular(
      sharedAiFile(session),
      64 * 1024,
      follow: false,
    );
    if (bytes == null) return null;
    final value = jsonDecode(utf8.decode(bytes));
    return value is Map<String, dynamic> ? value : null;
  } on Object {
    return null;
  }
}

bool sharedFileBroken(Session session) =>
    FileSystemEntity.typeSync(sharedAiFile(session), followLinks: false) !=
        FileSystemEntityType.notFound &&
    readSharedObject(session) == null;
