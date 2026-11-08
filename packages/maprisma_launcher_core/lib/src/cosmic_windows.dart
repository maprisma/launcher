/// COSMIC's stable foreign-toplevel identifiers; no shell or process-name
/// inference for window ownership.
library;

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'bounded.dart';
import 'desktop_entries.dart';
import 'running.dart';
import 'shlex.dart';

bool cosmicWindowMatches(Map window, Map app) {
  if (terminalCommand(app) != null) return false;
  final id = '${window['app_id'] ?? ''}'.toLowerCase();
  if (id.isEmpty) return false;
  final names = <String>{
    '${app['desktop_id'] ?? ''}'
        .replaceFirst(RegExp(r'\.desktop$'), '')
        .toLowerCase(),
    '${app['startup_class'] ?? ''}'.toLowerCase(),
  };
  try {
    final args = shlexSplit(app['exec'] as String? ?? '');
    if (args.isNotEmpty) names.add(p.basename(args.first).toLowerCase());
  } on FormatException {
    // A malformed Exec still has its explicit desktop id and StartupWMClass.
  }
  return names.contains(id);
}

Map<String, String> cosmicStates(
  Map<String, Map> apps,
  List<Map> windows,
  Set<String> names,
  Map<String, int> exes,
) {
  final background = runningApps(apps, names, exes);
  return {
    for (final e in apps.entries)
      if (windows.any((w) => cosmicWindowMatches(w, e.value)))
        e.key: 'active'
      else if (background.contains(e.key))
        e.key: 'background',
  };
}

/// Null means the desktop cannot provide window states.
bool inRunningCard(
  String key,
  Set<String> running,
  Map<String, String>? states,
) => states == null ? running.contains(key) : states[key] == 'active';

/// An app's windows, by workspace, the active one first.
List<Map<String, dynamic>> toplevelWindowsOf(Map app, List<Map> clients) {
  final windows = clients
      .where((w) => CosmicWindows.validId(w['id']) && cosmicWindowMatches(w, app))
      .toList();
  windows.sort((a, b) {
    final ws = (a['workspace'] as int? ?? 1 << 30).compareTo(
      b['workspace'] as int? ?? 1 << 30,
    );
    return ws != 0
        ? ws
        : (b['active'] == true ? 1 : 0).compareTo(
            a['active'] == true ? 1 : 0,
          );
  });
  return [
    for (final w in windows)
      {
        'address': w['id'],
        'title': '${w['title'] ?? ''}'.substring(
          0,
          '${w['title'] ?? ''}'.length.clamp(0, 120),
        ),
        'workspace': w['workspace'],
      },
  ];
}


/// A compositor's windows as `{id, app_id, title, workspace, active}`
/// (COSMIC through its helper, KDE Plasma through KWin scripts).
abstract class ToplevelWindows {
  /// Null: the desktop cannot list windows now.
  Future<List<Map>?> clients();
  Future<bool> focus(String id);
  Future<bool> closeWindow(String id);

  static bool validId(Object? id) => CosmicWindows.validId(id);

  List<Map<String, dynamic>> windowsOf(Map app, List<Map> clients) => toplevelWindowsOf(app, clients);
}

final class CosmicWindows extends ToplevelWindows {
  CosmicWindows(this.session, this.executable);
  final Session session;
  final String executable;
  static bool validId(Object? id) =>
      id is String &&
      id.isNotEmpty &&
      id.length <= 512 &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(id);

  Future<Map?> _run(List<String> args) async {
    final bundled = p.join(p.dirname(executable), 'maprisma-launcher-windows');
    final helper = File(bundled).existsSync()
        ? bundled
        : session.which('maprisma-launcher-windows');
    if (helper == null) return null;
    final text = await readBoundedText(
      [helper, ...args],
      maxBytes: 4 * 1024 * 1024,
      timeout: const Duration(seconds: 3),
      environment: session.environment,
    );
    try {
      final value = text == null ? null : jsonDecode(text);
      return value is Map ? value : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<List<Map>?> clients() async {
    final value = await _run(['list']);
    if (value?['available'] != true || value?['windows'] is! List) return null;
    return (value!['windows'] as List)
        .whereType<Map>()
        .where((w) => validId(w['id']))
        .toList();
  }

  @override
  Future<bool> focus(String id) async =>
      validId(id) && (await _run(['activate', id]))?['done'] == true;
  @override
  Future<bool> closeWindow(String id) async =>
      validId(id) && (await _run(['close', id]))?['done'] == true;
}
