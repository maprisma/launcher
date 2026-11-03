import 'dart:convert';
import 'dart:io';

import 'package:appmanager_core/appmanager_core.dart';

/// appmanager-core scan [--as-launcher]: the app list as JSON (for the
/// oracle: --as-launcher uses gnome-launcher's ids and cache folder).
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != 'scan') {
    stderr.writeln('usage: appmanager-core scan [--as-launcher]');
    exitCode = 2;
    return;
  }
  final launcher = args.contains('--as-launcher');
  final apps = await scanApps(
    Session(environment: Platform.environment),
    appIdPrefix: launcher
        ? 'io.github.ubruckhaus.Launcher'
        : 'io.github.ubruckhaus.AppManager',
    cacheName: launcher ? 'gnome-launcher' : 'appmanager',
  );
  stdout.writeln(jsonEncode(apps));
}
