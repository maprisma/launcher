import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';

/// maprisma-launcher-core scan [--as-launcher]: the app list as JSON (for the
/// oracle: --as-launcher uses gnome-launcher's ids and cache folder).
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != 'scan') {
    stderr.writeln('usage: maprisma-launcher-core scan [--as-launcher]');
    exitCode = 2;
    return;
  }
  final launcher = args.contains('--as-launcher');
  final apps = await scanApps(
    Session(environment: Platform.environment),
    appIdPrefix: launcher
        ? 'io.github.ubruckhaus.Launcher'
        : 'com.maprisma.Launcher',
    cacheName: launcher ? 'gnome-launcher' : 'maprisma-launcher',
    localized: !launcher,
  );
  stdout.writeln(jsonEncode(apps));
}
