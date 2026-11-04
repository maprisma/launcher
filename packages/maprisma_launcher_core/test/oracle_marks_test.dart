/// New-app stars, update parsing, process names and uninstall plans
/// against the Python reference.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('marks equal newapps.py, updates.py, launcher_core and details', () async {
    const day = 86400;
    final spec = {
      'notes': [
        [['a', 'b'], 1000 * day, {}],
        [['a', 'b', 'c', 'd', 'e'], 1001 * day, {'d': 990 * day, 'e': 1000 * day + 5}],
        [['c', 'f'], 1007 * day + 10, {}],
        [['g'], 1007 * day + 20, {'g': 0}],
      ],
      'opened': 'e',
      'update_text': 'firefox 1.0-1 -> 1.1-1\n  bad line\nyay 12.0-1 -> 12.1-1\nweird name! 1 -> 2\n',
      'owner_text': '/usr/share/applications/firefox.desktop is owned by firefox 1.0-1\nerror: nope\n',
      'flatpak_text': 'org.gnome.Maps\t49.1\nbad\norg.x.Y\t\n',
    };
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final live = Platform.environment['MAPRISMA_LIVE_TESTS'] == '1';
    final process = await Process.start('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'),
      live ? 'marks' : 'marks-portable']);
    process.stdin.write(jsonEncode(spec));
    await process.stdin.close();
    final err = process.stderr.transform(utf8.decoder).join();
    final expected = jsonDecode(await process.stdout.transform(utf8.decoder).join()) as Map;
    expect(await process.exitCode, 0, reason: await err);

    final data = emptySeen();
    final steps = <Object?>[];
    for (final [ids as List, now as int, installed as Map] in spec['notes'] as List) {
      final changed = noteSeen(data, ids.cast<String>(), 'apps', now: now, installed: installed.cast<String, num>());
      steps.add([changed, jsonDecode(jsonEncode(data)), {for (final k in ids) k: isNewApp(data, k as String, now: now)}]);
    }
    steps.add(openedApp(data, spec['opened'] as String));
    expect(steps, expected['notes']);
    expect({for (final e in parseUpdateLines(spec['update_text'] as String).entries) e.key: [e.value.$1, e.value.$2]},
        expected['updates']);
    expect(parseOwnerLines(spec['owner_text'] as String), expected['owners']);
    expect(parseFlatpakLines(spec['flatpak_text'] as String), expected['flatpaks']);

    if (!live) return;

    final session = Session(environment: Platform.environment);
    final apps = await scanApps(session, appIdPrefix: 'io.github.ubruckhaus.Launcher', cacheName: 'gnome-launcher', localized: false);
    // Deliberate difference: a terminal's --app-id (Omarchy TUIs) is no
    // browser web app here; the reference says ("webapp", "the browser").
    final want = Map<String, dynamic>.from(expected['apps'] as Map);
    for (final a in apps) {
      final exec = a['exec'] as String;
      if (exec.contains('--app-id=') && browserWebApp(a) == null) {
        final plan = uninstallPlan(a, session);
        (want[a['desktop_id']] as List)[2] = plan == null ? null : [plan.$1, plan.$2];
      }
    }
    expect({
      for (final a in apps)
        a['desktop_id']: [
          terminalCommand(a),
          appProcessName(a),
          switch (uninstallPlan(a, session)) { null => null, final (String, String?) plan => [plan.$1, plan.$2] },
        ],
    }, want);
  });

  test('process names see this test itself', () {
    final (names, exes) = processNames();
    expect(names, contains('dart'));
    expect(exes.keys, isNotEmpty);
  });
}
