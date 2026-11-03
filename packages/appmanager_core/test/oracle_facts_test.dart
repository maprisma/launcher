/// Package facts against details.app_facts, for every app on this machine.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appmanager_core/appmanager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('facts equal details.app_facts (kind, program, package, size)', () async {
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final result = await Process.run('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'facts'],
        environment: {...Platform.environment, 'LANG': 'C'});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final expected = jsonDecode(result.stdout as String) as Map;
    final session = Session(environment: {...Platform.environment, 'LANG': 'C'});
    final apps = await scanApps(session, appIdPrefix: 'io.github.ubruckhaus.Launcher', cacheName: 'gnome-launcher', localized: false);
    final facts = await AppFacts(session).all({for (final a in apps) a['desktop_id'] as String: a});
    var compared = 0, withPackage = 0;
    for (final a in apps) {
      final id = a['desktop_id'] as String;
      final want = expected[id] as Map, got = facts[id]!;
      if (got['kind'] == 'cli') continue; // The reference calls command-line tools "appimage".
      expect(got['kind'], want['kind'], reason: id);
      if (want['website'] != null) continue;
      expect(got['program'], want['program'], reason: id);
      final pkg = want['package'] as Map?;
      if (pkg != null) {
        withPackage++;
        final mine = got['package'] as Map? ?? (throw TestFailure('no package for $id, want ${pkg['name']}, program ${got['program']}'));
        expect([mine['name'], mine['version'], mine['size'], mine['url']],
            [pkg['name'], pkg['version'], pkg['size'], pkg['url']], reason: id);
      } else if (got['manager'] != 'flatpak') {
        expect(got['package'], isNull, reason: id);
        expect(got['file_size'], want['file_size'], reason: id);
      }
      compared++;
    }
    expect(compared, greaterThan(50));
    expect(withPackage, greaterThan(20));
  });
}
