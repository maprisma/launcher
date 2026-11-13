import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('pacman -Qi: Required By, wrapped lines too, None is empty', () {
    expect(parseRequiredBy('Name            : qt6-tools\nRequired By     : aurorae  kwin\n'
        '                  plasma-workspace\nOptional For    : None\n'), ['aurorae', 'kwin', 'plasma-workspace']);
    expect(parseRequiredBy('Required By     : None\nOptional For    : x\n'), isEmpty);
    expect(parseRequiredBy(null), isEmpty);
  });

  test('several packages in one line, never a hostile name', () {
    final managers = Managers(Session(environment: {'HOME': '/h', 'PATH': '/usr/bin:/bin'}));
    final argv = managers.removeManyCommand('pacman', ['a', 'b'], const [])!;
    expect(argv[2], startsWith('sudo pacman -Rns -- "\$@"'));
    expect(argv.sublist(3), ['uninstall', 'a', 'b']);
    expect(managers.removeManyCommand('pacman', ['a', '-Syu'], const []), isNull);
    expect(managers.removeManyCommand('pacman', const [], const []), isNull);
  });

  test('uninstall plans: needed packages are blocked, shared ones go once', () async {
    final home = Directory.systemTemp.createTempSync('am-unall-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory(p.join(home.path, 'bin'))..createSync();
    // pkg-a: needed by kwin (stays); pkg-c: needed only by pkg-d, which goes too.
    File(p.join(bin.path, 'pacman'))
      ..writeAsStringSync(r'''#!/bin/sh
case "$1" in
  -Qqo) case "$3" in */a1.desktop|*/a2.desktop) echo pkg-a;; */c.desktop) echo pkg-c;; */d.desktop) echo pkg-d;; esac;;
  -Qi) case "$3" in pkg-a) echo "Required By     : kwin";; pkg-c) echo "Required By     : pkg-d";; *) echo "Required By     : None";; esac;;
esac
''');
    Process.runSync('chmod', ['+x', p.join(bin.path, 'pacman')]);
    final system = Directory(p.join(home.path, 'system/applications'))..createSync(recursive: true);
    for (final name in ['a1', 'a2', 'c', 'd']) {
      File(p.join(system.path, '$name.desktop'))
          .writeAsStringSync('[Desktop Entry]\nType=Application\nName=App $name\nExec=/usr/bin/true\n');
    }
    final own = Directory(p.join(home.path, 'data/applications'))..createSync(recursive: true);
    File(p.join(own.path, 'mine.desktop'))
        .writeAsStringSync('[Desktop Entry]\nType=Application\nName=Mine\nExec=/usr/bin/true\n');
    final core = CoreService(environment: {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'XDG_DATA_HOME': p.join(home.path, 'data'),
      'XDG_DATA_DIRS': p.join(home.path, 'system'),
      'MAPRISMA_LAUNCHER_DESKTOP': 'cosmic',
    });
    Future<Map> call(String method, [Map<String, dynamic> params = const {}]) async =>
        jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})))
            as Map;
    await call('apps.list');
    String key(String dir, String file) => p.join(dir, file);
    final single = (await call('apps.uninstall_plan', {'key': key(system.path, 'a1.desktop')}))['result'] as Map;
    expect(single['what'], 'pkg-a');
    expect(single['needed_by'], ['kwin']);

    final plan = (await call('apps.uninstall_all_plan', {
      'keys': [
        for (final n in ['a1', 'a2', 'c', 'd']) key(system.path, '$n.desktop'),
        key(own.path, 'mine.desktop'),
      ],
    }))['result'] as Map;
    final packages = plan['packages'] as List;
    expect(packages, hasLength(1));
    expect(packages.first['manager'], 'pacman');
    expect((packages.first['what'] as List).toSet(), {'pkg-c', 'pkg-d'});
    final blocked = plan['blocked'] as List;
    expect(blocked, hasLength(1));
    expect(blocked.first['what'], 'pkg-a');
    expect(blocked.first['needed_by'], ['kwin']);
    expect([for (final a in blocked.first['apps'] as List) a['name']].toSet(), {'App a1', 'App a2'});
    expect([for (final a in plan['others'] as List) a['kind']], ['trash']);
    expect((await call('apps.uninstall_all_plan', {'keys': []}))['error'], isNotNull);
  });
}
