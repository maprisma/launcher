/// The dock's pure parts against dock_core.py (tools/oracle.py dock):
/// settings, the file operations, edge, sizes, dock_rect, inside, the
/// indicator colour, split_events, pinned operations, dropped_id, items and
/// the bar's edge.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final settingsCases = <Map<String, Object?>>[
  {},
  {'dock_enabled': true, 'dock_position': 'left', 'dock_height': 64, 'dock_icon_size': 48.0, 'dock_magnify': 150},
  {'dock_enabled': 1, 'dock_autohide': 'yes', 'dock_height': true, 'dock_icon_size': 33, 'dock_position': 'middle'},
  {'dock_spacing': 0, 'dock_align': 'end', 'dock_indicator': 'dot', 'dock_indicator_color': 'green', 'dock_bounce': true},
  {
    'dock_pinned': ['a.desktop', 'b.desktop', 'a.desktop', '', 7, null, 'x' * 300, 'y' * 301, 'ü' * 300, 'c.desktop'],
  },
  {'dock_pinned': [for (var i = 0; i < 70; i++) 'app$i.desktop']},
  {'dock_pinned': 'a.desktop', 'dock_full_width': false, 'dock_rounded': true, 'dock_transparent': null},
];

final fileOps = <List<Object?>>[
  ['set', 'dock_enabled', true],
  ['set', 'dock_height', 72],
  ['set', 'dock_height', 73],
  ['set', 'dock_height', true],
  ['set', 'dock_position', 'top'],
  ['set', 'dock_autohide', 1],
  ['set', 'dock_rounded', ''],
  ['set', 'dock_pinned', ['a']],
  ['set', 'no_such', 1],
  ['pin', 'firefox.desktop'],
  ['pin', 'files.desktop'],
  ['pin', 'firefox.desktop'],
  ['set_pinned', ['b', 'a', 'b', 'c']],
  ['unpin', 'a'],
  ['unpin', 'zzz'],
  ['reset'],
];

final layers = {
  'DP-1': {
    'levels': {
      '0': [
        {'namespace': 'wallpaper', 'x': 0, 'y': 0, 'w': 2560, 'h': 1440},
      ],
      '2': [
        {'namespace': 'omarchy-bar', 'x': 0, 'y': 0, 'w': 2560, 'h': 30},
        {'namespace': 'app-manager-dock', 'x': 900, 'y': 1380, 'w': 760, 'h': 60},
      ],
    },
  },
};
final monitors = [
  {'name': 'DP-1', 'x': 1920, 'y': 0},
  {'name': 'eDP-1'},
];

final apps = [
  {'desktop_id': 'firefox.desktop', 'name': 'Firefox', 'exec': 'firefox %u', 'startup_class': 'firefox'},
  {'desktop_id': 'org.gnome.Nautilus.desktop', 'name': 'Files', 'exec': 'nautilus --new-window', 'startup_class': ''},
  {'desktop_id': 'alacritty.desktop', 'name': 'Alacritty', 'exec': 'alacritty', 'startup_class': ''},
  {'desktop_id': 'zed.desktop', 'name': 'zed', 'exec': 'zeditor %U', 'startup_class': 'dev.zed.Zed'},
  {'desktop_id': 'btop.desktop', 'name': 'Btop', 'exec': 'btop', 'tray_id': 'x'},
  {'desktop_id': 'chromium.desktop', 'name': 'Chromium', 'exec': 'chromium', 'startup_class': ''},
  {'desktop_id': '', 'name': 'Nameless', 'exec': 'x'},
];
final clients = [
  {'address': '0xa1', 'class': 'firefox', 'focusHistoryID': 3, 'mapped': true},
  {'address': '0xa2', 'class': 'firefox', 'focusHistoryID': 0},
  {'address': '0xa3', 'class': 'Alacritty', 'focusHistoryID': 2},
  {'address': '0xa4', 'class': 'dev.zed.Zed', 'focusHistoryID': 1},
  {'address': '0xa5', 'class': 'alacritty', 'focusHistoryID': 2},
  {'address': '0xa6', 'class': 'chromium', 'mapped': false},
  {'address': '0xa7', 'class': 'btop', 'focusHistoryID': 4},
  {'address': '0xa8', 'class': 'org.gnome.Nautilus', 'focusHistoryID': 5},
];

List<int> b(String s) => utf8.encode(s);

void main() {
  test('dock_core equals the reference', () async {
    final spec = {
      'settings': settingsCases,
      'file_start': {'language': 'de', 'dock_pinned': ['a', 'b']},
      'file_ops': fileOps,
      'bars': [
        '{"bar": {"position": "bottom"}}',
        '{"bar": {"position": "middle"}}',
        '{"bar": []}',
        '[1]',
        'not json',
        '',
        '{"bar": {"position": "left"}, "other": 1}',
        null,
      ],
      'edges': [
        for (final pos in dockPositions)
          for (final bar in dockPositions) [pos, bar],
      ],
      'sizes': [
        {},
        {'dock_height': 32, 'dock_icon_size': 48},
        {'dock_icon_size': 40, 'dock_magnify': 125},
        {'dock_icon_size': 24, 'dock_magnify': 150, 'dock_bounce': true},
        {'dock_height': 96, 'dock_icon_size': 24},
        {'dock_icon_size': 72, 'dock_magnify': 175, 'dock_bounce': true},
        {'dock_icon_size': 56, 'dock_magnify': 125}, // 14
        {'dock_icon_size': 40, 'dock_magnify': 175}, // 30
        {'dock_icon_size': 24, 'dock_magnify': 125}, // 6.0
        {'dock_icon_size': 72, 'dock_magnify': 125}, // 18.0
      ],
      'rects': [
        [layers, monitors],
        [layers, []],
        [{'DP-1': {'levels': {'2': [{'namespace': 'app-manager-dock', 'x': '5', 'y': 7.9, 'w': true, 'h': 3}]}}}, null],
        [{'DP-1': {'levels': {'2': [{'namespace': 'app-manager-dock', 'x': 1, 'y': 2, 'w': null, 'h': 3}]}}}, null],
        [{'DP-1': {'levels': {'2': 'x'}}, 'X': 5}, monitors],
        [[], monitors],
        [{'HDMI': {'levels': {}}}, monitors],
      ],
      'inside': [
        [{'x': 900, 'y': 1380}, [900, 1380, 760, 60]],
        [{'x': 1660, 'y': 1400}, [900, 1380, 760, 60]],
        [{'x': 1659, 'y': 1439}, [900, 1380, 760, 60]],
        [{'y': 1400}, [900, 1380, 760, 60]],
        [{'x': -1, 'y': -1}, [-1, -1, 1, 1]],
        [null, [0, 0, 10, 10]],
        [[1, 2], [0, 0, 10, 10]],
      ],
      'colors': [
        [{}, {'accent': '#112233', 'red': '#ff0000'}],
        [{'dock_indicator_color': 'red'}, {'accent': '#112233', 'red': '#ff0000'}],
        [{'dock_indicator_color': 'green'}, {'accent': '#112233'}],
        [{'dock_indicator_color': 'foreground'}, {'foreground': '#eeeeee'}],
        [{'dock_indicator_color': 'yellow'}, {'yellow': ''}],
        [{'dock_indicator_color': 'theme'}, {}],
      ],
      'new_window': [
        {'actions': [{'id': 'new-window', 'name': 'New Window'}]},
        {'actions': [{'id': 'New_Window'}]},
        {'actions': [{'id': 'newwindow'}]},
        {'actions': [{'id': 'new-private-window'}]},
        {'actions': []},
        {},
        {'actions': null},
      ],
      'events': [
        [
          [b('openwindow>>a1,1,firefox,Title\nactivewindowv2>>a1\nclos'), b('ewindow>>a1\n'), b('')],
          4096,
        ],
        [
          [b('urgent>>ff\nwindowtitlev2>>ff,${'x' * 40}'), b('${'y' * 40}\nfocusedmon>>DP-1\n'), b('tail')],
          30,
        ],
        [
          [b('a' * 20), b('b' * 20), b('c\nok\n')],
          16,
        ],
        [
          [b('é\n'), [0xff, 0xfe, 10], b('ü'), b('\n')],
          4096,
        ],
      ],
      'moves': [
        [['a', 'b', 'c'], 'a', 'c', false],
        [['a', 'b', 'c'], 'a', 'c', true],
        [['a', 'b', 'c'], 'c', 'a', false],
        [['a', 'b', 'c'], 'b', 'b', false],
        [['a', 'b', 'c'], 'a', 'zzz', true],
        [['a', 'b', 'c'], 'new', 'b', true],
      ],
      'inserts': [
        [['a', 'b'], 'c', null, false],
        [['a', 'b'], 'c', 'a', false],
        [['a', 'b'], 'c', 'a', true],
        [['a', 'b'], 'b', 'a', false],
        [['a', 'b'], 'c', 'zzz', false],
        [[for (var i = 0; i < 60; i++) 'p$i'], 'c', 'p0', false],
      ],
      'drops': [
        b('app-manager-entry:firefox.desktop'),
        b('  app-manager-entry:firefox.desktop\n'),
        [...b('app-manager-entry:x.desktop'), 0, 0],
        b('app-manager-entry:'),
        b('app-manager-entry:a\nb'),
        b('other:firefox.desktop'),
        b('app-manager-entry:${'z' * 300}'),
        b('app-manager-entry:${'z' * 301}'),
        b('app-manager-entry:${'ü' * 240}'),
        [0xff, 0xfe],
        b(' app-manager-entry:s.desktop　'),
        'app-manager-entry:string.desktop',
        null,
      ],
      'items': {
        'apps': apps,
        'pinned': ['zed.desktop', 'missing.desktop', 'firefox.desktop'],
        'clients': clients,
      },
    };
    final env = {...Platform.environment, 'LANG': 'C'};
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final proc = await Process.start('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'dock'],
        environment: env);
    proc.stdin.write(jsonEncode(spec));
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    expect(await proc.exitCode, 0, reason: err);
    final expected = jsonDecode(out) as Map;

    expect([for (final raw in settingsCases) dockSettings(raw)], expected['settings']);

    final home = Directory.systemTemp.createTempSync('dock-oracle-');
    addTearDown(() => home.deleteSync(recursive: true));
    final store = ConfigStore(Session(environment: {'HOME': home.path}), dir: home.path);
    store.writeJson('settings.json', spec['file_start']);
    final dock = DockStore(store);
    final steps = [];
    for (final op in fileOps) {
      String? error;
      try {
        switch (op[0]) {
          case 'set':
            dock.set(op[1] as String, op[2]);
          case 'reset':
            dock.reset();
          case 'pin':
            dock.pin(op[1] as String);
          case 'unpin':
            dock.unpin(op[1] as String);
          case 'set_pinned':
            dock.setPinned((op[1] as List).cast<String>());
        }
      } on ArgumentError catch (e) {
        // The reference: KeyError for an unknown key, ValueError for a value.
        error = dockDefaults.containsKey(e.message) && e.message != 'dock_pinned' ? 'ValueError' : 'KeyError';
      }
      steps.add([error, dock.read(), store.readJson('settings.json')]);
    }
    expect(steps, expected['file_ops']);

    final shell = p.join(home.path, 'shell.json');
    final bars = [];
    for (final text in spec['bars'] as List) {
      if (text == null) {
        File(shell).deleteSync();
      } else {
        File(shell).writeAsStringSync(text as String);
      }
      bars.add(barPosition(Session(environment: {'HOME': home.path}), path: shell));
    }
    expect(bars, expected['bars']);

    expect([for (final e in spec['edges'] as List) dockEdge({'dock_position': e[0]}, e[1] as String)], expected['edges']);
    expect([
      for (final d in spec['sizes'] as List)
        (() {
          final (band, item, room) = dockSizes({...dockDefaults, ...d as Map});
          return [band, item, room];
        })(),
    ], expected['sizes']);
    expect([
      for (final r in spec['rects'] as List)
        (() {
          final found = dockRect(r[0], r[1], namespace: 'app-manager-dock');
          if (found == null) return null;
          final ((x, y, w, h), (ox, oy)) = found;
          return [[x, y, w, h], [ox, oy]];
        })(),
    ], expected['rects']);
    expect([
      for (final c in spec['inside'] as List)
        dockInside(c[0], (c[1][0] as num, c[1][1] as num, c[1][2] as num, c[1][3] as num)),
    ], expected['inside']);
    expect([for (final c in spec['colors'] as List) dockIndicatorColor(c[0] as Map, c[1] as Map)], expected['colors']);
    expect([for (final a in spec['new_window'] as List) hasNewWindowAction(a as Map)], expected['new_window']);
    expect([
      for (final e in spec['events'] as List)
        (() {
          List<int> buffer = const [];
          var skipping = false;
          final lines = [];
          for (final chunk in e[0] as List) {
            final (got, rest, skip) = splitEvents(buffer, (chunk as List).cast<int>(), skipping, limit: e[1] as int);
            buffer = rest;
            skipping = skip;
            lines.add(got);
          }
          return [lines, buffer.toList(), skipping];
        })(),
    ], expected['events']);
    expect([
      for (final m in spec['moves'] as List) movePinned((m[0] as List).cast<String>(), m[1] as String, m[2] as String, after: m[3] as bool),
    ], expected['moves']);
    expect([
      for (final m in spec['inserts'] as List)
        insertPinned((m[0] as List).cast<String>(), m[1] as String, target: m[2] as String?, after: m[3] as bool),
    ], expected['inserts']);
    expect([for (final d in spec['drops'] as List) droppedId(d is List ? d.cast<int>() : d)], expected['drops']);
    final mapped = dockClients(clients);
    expect([for (final c in mapped) c['address']], expected['clients']);
    expect([
      for (final (app, windows, pinned) in dockItems(apps, ['zed.desktop', 'missing.desktop', 'firefox.desktop'], mapped))
        [app['desktop_id'], [for (final w in windows) w['address']], pinned],
    ], expected['items']);
    // What the reference says here, spelled out once.
    expect(expected['items'], [
      ['zed.desktop', ['0xa4'], true],
      ['firefox.desktop', ['0xa2', '0xa1'], true],
      ['alacritty.desktop', ['0xa3', '0xa5'], false], // (Files: its window class is not one of its own)
    ]);
  });

  test('Hyprland events: urgent, seen, closed; which ones refresh', () {
    final urgent = <String>{};
    expect(dockEvent('urgent>>55aa', urgent), isTrue);
    expect(urgent, {'0x55aa'});
    expect(dockEvent('workspace>>2', urgent), isFalse);
    expect(dockEvent('activewindowv2>>55aa', urgent), isTrue);
    expect(urgent, isEmpty);
    dockEvent('urgent>>1', urgent);
    expect(dockEvent('closewindow>>1', urgent), isTrue);
    expect(urgent, isEmpty);
    for (var i = 0; i < 300; i++) {
      dockEvent('urgent>>$i', urgent);
    }
    expect(urgent, hasLength(256));
    expect(dockEvent('openwindow>>${'x' * 5000}', <String>{}), isTrue);
    expect(HyprEvents.socketPath({'HYPRLAND_INSTANCE_SIGNATURE': 'abc', 'XDG_RUNTIME_DIR': '/run/user/1'}),
        '/run/user/1/hypr/abc/.socket2.sock');
    expect(HyprEvents.socketPath({'HYPRLAND_INSTANCE_SIGNATURE': '../x', 'XDG_RUNTIME_DIR': '/run'}), isNull);
    expect(HyprEvents.socketPath({'XDG_RUNTIME_DIR': '/run'}), isNull);
  });

  test('HyprEvents reads a socket in lines and drops a huge one', () async {
    final dir = Directory.systemTemp.createTempSync('dock-ev-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, '.socket2.sock');
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    addTearDown(server.close);
    server.listen((client) async {
      client.add(utf8.encode('openwindow>>a1,1,x,t\nwindowtitlev2>>a1,'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      client.add(utf8.encode('${'t' * 10000}\nactivewindowv2>>a1\n'));
      await client.flush();
      await client.close();
    });
    final stop = Completer<void>();
    final got = <String>[];
    await for (final line in HyprEvents(path).lines(stop: stop.future)) {
      got.add(line);
      if (got.length == 2) stop.complete();
    }
    expect(got, ['openwindow>>a1,1,x,t', 'activewindowv2>>a1']);
  });
}
