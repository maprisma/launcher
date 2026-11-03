/// Groups and origins against the Python references.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/groups.dart' as groups;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final repo = p.normalize(p.join(Directory.current.path, '../..'));

Future<Object?> oracle(List<String> args, {String? input, Map<String, String>? env}) async {
  final process = await Process.start(
    '/usr/bin/python3',
    ['-I', '-B', p.join(repo, 'tools/oracle.py'), ...args],
    environment: env,
  );
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final out = await process.stdout.transform(utf8.decoder).join();
  final err = await process.stderr.transform(utf8.decoder).join();
  expect(await process.exitCode, 0, reason: err);
  return jsonDecode(out);
}

Map<String, dynamic> app(String id, {List<String> categories = const [], bool pwa = false}) => {
  'desktop_id': id,
  'name': id,
  'categories': categories,
  'pwa': pwa,
};

/// The same operations on the Dart port, results in the oracle's shape.
Map<String, dynamic> runDart(Map<String, dynamic> spec) {
  final data = groups.cleanPage(spec['data'], const ['o-defaults', 'o-system', 'o-flatpak', 'o-user']);
  final apps = [for (final a in spec['apps'] as List) a as Map];
  final results = <Object?>[];
  for (final op in spec['ops'] as List) {
    final name = op[0] as String, args = (op as List).sublist(1);
    Object? result;
    try {
      result = switch (name) {
        'sections' => [
          for (final (gid, members) in groups.sections(apps, data))
            [gid, [for (final a in members) a['desktop_id']]],
        ],
        'group_of' => [for (final a in apps) groups.groupOf(a, data)],
        'place' => () {
          final gid = args[1] as String;
          final ids = [
            for (final (g, members) in groups.sections(apps, data))
              if (g == gid) for (final a in members) a['desktop_id'] as String,
          ];
          groups.place(data, args[0] as String, gid, args[2] as String?, ids, after: args[3] == true);
          return null;
        }(),
        'clean_name' => groups.cleanName(args[0]),
        'add_group' => groups.addGroup(data, args[0] as String),
        'rename_group' => () {
          groups.renameGroup(data, args[0] as String, args[1] as String);
          return null;
        }(),
        'delete_group' => () {
          groups.deleteGroup(data, args[0] as String);
          return null;
        }(),
        'move_group' => groups.moveGroup(data, args[0] as String, args[1] as int),
        'reorder_group' => groups.reorderGroup(data, args[0] as String, args[1] as String, after: args[2] == true),
        'toggle_collapsed' => () {
          groups.toggleCollapsed(data, args[0] as String);
          return null;
        }(),
        'assign' => () {
          groups.assign(data, args[0] as String, args[1] as String);
          return null;
        }(),
        _ => throw StateError(name),
      };
    } on groups.GroupError catch (e) {
      result = {'error': e.message};
    }
    results.add(result);
  }
  return {'results': results, 'data': data};
}

void main() {
  test('group operations equal groups.py', () async {
    final spec = {
      'data': {
        'groups': [
          {'id': 'office', 'name': ''},
          {'id': 'media', 'name': '  My   Media '},
          {'id': 'g1', 'name': 'AI', 'new': true},
          {'id': 'g2', 'name': ''},
          {'id': 'BAD ID', 'name': 'x'},
          {'id': 'other', 'name': 'x'},
          {'id': 'office', 'name': 'dup'},
          'junk',
        ],
        'members': {'zed': 'g1', 'ghost': 'nope', '': 'office'},
        'collapsed': ['media', 'o-system', 'nope'],
        'order': ['b', 'b', 7, 'a'],
      },
      'apps': [
        app('a', categories: ['Office']),
        app('b', categories: ['Office', 'Development']),
        app('c', categories: ['Game']),
        app('d', pwa: true),
        app('e'),
        app('zed', categories: ['AudioVideo']),
        app('f', categories: ['Utility', 'Development']),
      ],
      'ops': [
        ['group_of'],
        ['sections'],
        ['clean_name', 'a\u202eb\t\tc ${'x' * 50}'],
        ['add_group', 'Media'],
        ['add_group', 'my media'],
        ['add_group', 'Other'],
        ['add_group', '  '],
        ['add_group', 'Work'],
        ['place', 'e', 'g3', null, false],
        ['place', 'c', 'g3', 'e', false],
        ['place', 'a', 'office', 'b', true],
        ['sections'],
        ['rename_group', 'g3', 'AI'],
        ['rename_group', 'g3', 'Jobs'],
        ['move_group', 'office', -1],
        ['move_group', 'office', 1],
        ['reorder_group', 'g3', 'office', false],
        ['reorder_group', 'g3', 'g3', false],
        ['toggle_collapsed', 'g3'],
        ['toggle_collapsed', 'media'],
        ['assign', 'f', 'nope'],
        ['delete_group', 'g1'],
        ['group_of'],
        ['sections'],
      ],
    };
    final expected = await oracle(['groups'], input: jsonEncode(spec));
    expect(jsonDecode(jsonEncode(runDart(spec))), expected);
  });

  for (final desktop in ['omarchy', 'gnome']) {
    test('origins and default apps on this machine as $desktop', () async {
      final env = {
        ...Platform.environment,
        'LANG': 'C',
        if (desktop == 'gnome') 'XDG_CURRENT_DESKTOP': 'GNOME',
      };
      final expected = await oracle(['origins', if (desktop == 'omarchy') 'omarchy'], env: env) as Map;
      final session = Session(environment: env);
      final adapter = desktop == 'omarchy' ? OmarchyDesktop(session) : GnomeDesktop(session);
      final apps = await scanApps(session, appIdPrefix: 'io.github.ubruckhaus.Launcher', cacheName: 'gnome-launcher', localized: false);
      final defaults = adapter.defaultDesktops();
      expect(defaults.toList()..sort(), expected['defaults']);
      expect({for (final a in apps) a['desktop_id']: adapter.origin(a, defaults)}, expected['origin']);
      expect({for (final a in apps) a['desktop_id']: adapter.defaultRoles(a)}, expected['roles']);
    });
  }
}
