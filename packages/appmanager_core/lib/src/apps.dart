/// The whole app list: launcher_core.parse_desktop_files.
library;

import 'package:path/path.dart' as p;

import 'appimages.dart';
import 'cli_tools.dart';
import 'desktop_entries.dart';
import 'shlex.dart';

Future<List<Map<String, dynamic>>> scanApps(
  Session session, {
  String appIdPrefix = 'io.github.ubruckhaus.AppManager',
  String cacheName = 'appmanager',
}) async {
  final seenNames = <String>{};
  final apps = scanDesktopEntries(session, seenNames);
  // An AppImage a .desktop file already starts is that app.
  final started = <String>{};
  for (final app in apps) {
    final program = execProgram(app['exec'] as String);
    if (program != null && program.toLowerCase().endsWith('.appimage')) {
      started.add(program);
    }
  }
  apps.addAll(
    await scanStandaloneAppImages(
      session,
      seenNames,
      started: started,
      cacheName: cacheName,
    ),
  );
  final known = <String>{};
  for (final app in apps) {
    try {
      known.addAll(shlexSplit(app['exec'] as String).map(p.basename));
    } on FormatException {
      // An Exec line shlex cannot read names no command.
    }
  }
  apps.addAll(
    cliEntries(known, session, appIdPrefix: appIdPrefix).where(
      (e) => !seenNames.contains((e['name'] as String).trim().toLowerCase()),
    ),
  );
  final indexed = [for (var i = 0; i < apps.length; i++) (i, apps[i])];
  indexed.sort((a, b) {
    final r = (a.$2['name'] as String).toLowerCase().compareTo(
      (b.$2['name'] as String).toLowerCase(),
    );
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
