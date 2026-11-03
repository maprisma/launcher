/// The plugin list against the Omarchy plugin's parse_plugins (this machine; reads only).
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('plugins equal parse_plugins', () async {
    final session = Session(environment: Platform.environment);
    if (session.which('omarchy-shell') == null) return; // Omarchy only
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final r = await Process.run('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'plugins'],
        environment: {...Platform.environment, 'LANG': 'C'});
    expect(r.exitCode, 0, reason: '${r.stderr}');
    // The reference lists the old App Manager itself as its own entry; ours skips
    // ourselves (ubruckhaus.maprisma-launcher) instead.
    final expected = [
      for (final e in jsonDecode(r.stdout as String) as List)
        if (e['plugin_id'] != 'ubruckhaus.maprisma-launcher') e,
    ];
    const keys = ['plugin_id', 'name', 'description', 'bar_widget', 'in_bar', 'openable', 'removable', 'category',
      'plugin_dir', 'bar_section'];
    final got = [for (final pl in await ShellPlugins(session).list()) {for (final k in keys) k: pl[k]}];
    expect(got, expected);
    expect(got, isNotEmpty);
  });
}
