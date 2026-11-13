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

import 'package:path/path.dart' as p;

import 'config.dart';
import 'desktop_entries.dart';

const aiAuto = 'auto';
const aiSettingsName = 'settings.json';
final aiHelperPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$');

/// Whether [value] may be stored as the shared choice.
bool validAiChoice(Object? value) => value == aiAuto || (value is String && aiHelperPattern.hasMatch(value));

/// The shared settings folder (`maprisma-ai` in the config home).
String aiSettingsDir(Session session) {
  final config = session.environment['XDG_CONFIG_HOME'] ?? '';
  return p.join(config.startsWith('/') ? config : p.join(session.home, '.config'), 'maprisma-ai');
}

ConfigStore _store(Session session) => ConfigStore(session, dir: aiSettingsDir(session));

/// The shared choice. When the shared file does not exist yet, [legacy] (the
/// Launcher's own former `ask_helper`) is used if valid.
String readAiChoice(Session session, {Object? legacy}) {
  final store = _store(session);
  if (FileSystemEntity.typeSync(store.path(aiSettingsName), followLinks: false) == FileSystemEntityType.notFound) {
    return legacy is String && validAiChoice(legacy) ? legacy : aiAuto;
  }
  final data = store.readJson(aiSettingsName);
  final helper = data is Map ? data['helper'] : null;
  return validAiChoice(helper) ? helper as String : aiAuto;
}

/// Whether web discovery is on for all Maprisma apps: the shared file's
/// boolean `web_search`, set in Maprisma Settings › AI. Missing, invalid or no
/// file = off.
bool readAiWebSearch(Session session) {
  final data = _store(session).readJson(aiSettingsName);
  return data is Map && data['web_search'] == true;
}

/// Helpers with a documented web-only mode (search and fetch, no other
/// tools): only Claude Code (`--tools WebSearch,WebFetch`).
const webSearchHelpers = {'claude'};

/// Store [value] as the shared choice; other keys in the file stay.
void writeAiChoice(Session session, String value) {
  if (!validAiChoice(value)) throw ArgumentError.value(value, 'helper');
  final store = _store(session);
  final old = store.readJson(aiSettingsName);
  store.writeJson(aiSettingsName, {if (old is Map) ...old.cast<String, dynamic>(), 'helper': value});
}

/// The helper id to use for [choice] among [states] (helperStates' entries):
/// the chosen one when installed, else the first installed that seems signed
/// in, else the first installed; null when none is.
String? resolveAiChoice(String choice, List<Map<String, dynamic>> states) {
  final installed = [for (final h in states) if (h['installed'] == true) h];
  if (choice != aiAuto) {
    final hit = installed.where((h) => h['command'] == choice).firstOrNull;
    if (hit != null) return choice;
  }
  return ((installed.where((h) => h['signed_in'] == true).firstOrNull ?? installed.firstOrNull)?['command']) as String?;
}
