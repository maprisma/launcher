/// Shortcuts against both references' shortcuts.py (tools/oracle.py
/// shortcuts): combos and labels, state cleaning, COSMIC's file through
/// several saves, GNOME's bindings and saves on a fake GSettings, Hyprland's
/// binds, files, bindings and the generated module. No desktop is touched:
/// every input is given, the files live in a temporary folder.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
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

/// gnome-launcher's GSettings over a map, as the oracle's FakeGSettings.
final class FakeKeySettings implements KeySettings {
  FakeKeySettings(this.db);
  final Map<String, dynamic> db;
  Map get _bindings => db['bindings'] as Map;
  Map get _custom => db['custom'] as Map;

  @override
  Future<bool> available() async => true;
  @override
  Future<List<(String, String, String, List<String>)>> bindingKeys() async => [
    for (final MapEntry(key: schema, value: keys) in _bindings.entries)
      for (final MapEntry(key: key, value: accels) in (keys as Map).entries)
        ('$schema', '$key', '$key', [for (final a in accels as List) '$a']),
  ];
  @override
  Future<List<String>> getStrv(String schema, String key) async =>
      [for (final a in ((_bindings[schema] as Map?)?[key] as List?) ?? const []) '$a'];
  @override
  Future<void> setStrv(String schema, String key, List<String> values) async =>
      (_bindings.putIfAbsent(schema, () => <String, dynamic>{}) as Map)[key] = [...values];
  @override
  Future<List<String>> customPaths() async => [for (final x in db['paths'] as List) '$x'];
  @override
  Future<void> setCustomPaths(List<String> paths) async => db['paths'] = [...paths];
  @override
  Future<Map<String, String>> readCustom(String path) async {
    final values = (_custom[path] as Map?) ?? const {};
    return {for (final k in const ['name', 'command', 'binding']) k: '${values[k] ?? ''}'};
  }

  @override
  Future<void> writeCustom(String path, Map<String, String> values) async =>
      (_custom.putIfAbsent(path, () => <String, dynamic>{}) as Map).addAll(values);
  @override
  Future<void> resetCustom(String path) async => _custom.remove(path);
  @override
  Future<void> sync() async {}
}

String commandOf(List<String> launch, String action) => shlexJoin([...launch, if (action.isNotEmpty) action]);

Object? roundTrip(Object? value) => jsonDecode(jsonEncode(value));

Map<String, dynamic> answers(ShortcutBindings bindings, List<Map> apps, List queries, {bool gnome = true}) => {
  'classify': [
    for (final q in queries)
      () {
        final (level, owner) = bindings.classify(
          q[0] as Map,
          q[1] as String,
          app: q[2] == null ? null : apps[q[2] as int],
          action: q[3] as String,
        );
        return [level, owner];
      }(),
  ],
  'external': [for (final app in apps) bindings.externalShortcuts(app)],
  'suggest': [
    for (final app in apps)
      [
        bindings.suggestions(app, shortcutAppKey(app)),
        bindings.suggestions(app, shortcutAppKey(app), mods: ['SUPER', 'ALT']),
      ],
  ],
  'taken_from': gnome ? [for (final q in queries) bindings.takenFrom(q[0] as Map)] : null,
};

const selfKey = 'plugin:ubruckhaus.simple-launcher-for-fools';
const ff = '/usr/share/applications/firefox.desktop';
const files = '/usr/share/applications/org.gnome.Nautilus.desktop';

final apps = <Map<String, dynamic>>[
  {
    'desktop_path': ff,
    'desktop_id': 'firefox',
    'name': 'Firefox',
    'exec': '/usr/lib/firefox/firefox %u',
    'actions': [
      {'id': 'new-window', 'name': 'New Window', 'exec': '/usr/lib/firefox/firefox --new-window %u'},
      {'id': 'new-private-window', 'name': 'New Private Window', 'exec': 'firefox --private-window %u'},
    ],
  },
  {'desktop_path': files, 'desktop_id': 'org.gnome.Nautilus', 'name': 'Files', 'exec': 'nautilus --new-window', 'actions': []},
  {
    'desktop_path': '/usr/share/applications/Alacritty.desktop',
    'desktop_id': 'Alacritty',
    'name': 'Alacritty',
    'exec': 'alacritty',
    'actions': [],
  },
  {
    'desktop_path': '/home/u/.local/share/applications/YouTube.desktop',
    'desktop_id': 'YouTube',
    'name': 'YouTube',
    'exec': 'omarchy-launch-webapp "https://youtube.com/"',
    'actions': [],
  },
  {'desktop_id': 'btop', 'name': 'btop', 'exec': 'btop', 'argv': ['btop'], 'actions': [
    {'id': 'incognito', 'name': 'Incognito', 'exec': 'btop --x'},
  ]},
];

Map<String, dynamic> c(List<String> mods, String key, [String? then]) => {'mods': mods, 'key': key, 'then': ?then};

final queries = [
  [c(['SUPER'], '1'), ff, 0, ''],
  [c(['SUPER'], 'E'), files, 1, ''],
  [c(['SUPER'], 'Q'), ff, null, ''],
  [c(['SUPER', 'ALT'], 'P'), ff, 0, ''],
  [c(['SUPER', 'ALT'], 'P'), ff, 0, 'new-private-window'],
  [c(['SUPER', 'SHIFT'], 'Z'), files, 1, ''],
  [c(['SUPER'], 'space'), files, 1, ''],
  [c(['SUPER', 'ALT'], 'O'), files, null, ''],
  [c(['SUPER'], 'Return'), '/usr/share/applications/Alacritty.desktop', 2, ''],
  [c(['SUPER', 'SHIFT'], 'B'), ff, 0, ''],
  [c(['SUPER', 'SHIFT', 'ALT'], 'B'), ff, 0, 'new-private-window'],
  [c(['SUPER', 'ALT'], 'SPACE'), files, 1, ''],
  [c(['SUPER', 'ALT'], 'F'), ff, 0, ''],
  [c(['SUPER', 'SHIFT'], 'Y'), '/home/u/.local/share/applications/YouTube.desktop', 3, ''],
  [c(['SUPER', 'ALT'], 'T'), 'btop', 4, ''],
  [c(['SUPER'], 'code:10'), ff, null, ''],
  [c(['SUPER', 'SHIFT'], 'F'), ff, 0, ''],
];

const base = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/';

final spec = <String, dynamic>{
  'combos': {
    'make': [
      [['SUPER', 'SHIFT'], 'b', null],
      [['ALT', 'SUPER'], 'Return', null],
      [<String>[], '', null],
      [['SUPER'], 'code:38', 'n'],
      [['SUPER'], 'a b', null],
      [['SUPER', 'CTRL', 'BOGUS'], 'Space', 'x'],
      [['SUPER'], 'x', 'bad key!'],
      ['SUPER', 'a', null],
    ],
    'accels': [
      '<Super><Shift>b', '<Primary>Return', '<Hyper>x', '', '<Super>', '<Super>KP_1', ' <Alt>F4 ',
      '<Control><Alt><Super><Shift>Page_Up', '<super>a', '<Mod1>space',
    ],
    'hypr': [
      'SUPER + SHIFT + B', 'super, return', 'WIN + code:10', 'HYPER + X', '', 'CTRL + ALT + Delete', 'SUPER+',
      'MOD1 + MOD4 + space',
    ],
    'keys': [...keyMapKeys.where((k) => !const {'bracketleft', 'bracketright', 'backslash', 'Delete', 'Insert', 'Home', 'End'}.contains(k)), 'ABOVE_TAB', 'Escape', 'page_up', 'a', 'code:38'],
    'pairs': [
      [c(['SUPER'], 'A'), c(['SUPER'], 'a')],
      [c(['SUPER'], 'SPACE', 'N'), c(['SUPER'], 'SPACE')],
      [c(['SUPER'], 'SPACE', 'N'), c(['SUPER'], 'SPACE', 'P')],
      [c(['SUPER'], 'A'), c(['SUPER', 'SHIFT'], 'A')],
    ],
  },
  'apps': apps,
  'queries': queries,
  'gnome_states': [
    null,
    [],
    {'apps': []},
    {
      'apps': {
        'a': {
          'name': null,
          'launch': ['x'],
          'shortcuts': [
            {'mods': 'SUPER', 'key': 'a'},
            {
              'mods': ['CTRL', 'SUPER', 'FOO'],
              'key': 'return',
              'replaces': null,
              'action': 'bad action!',
              'taken_from': 'nope',
              'label': 'L',
            },
            {'mods': ['ALT'], 'key': 5, 'action': 'new-window', 'label': 'New ${'w' * 100}', 'taken_from': 'custom:${base}custom0/'},
            {'key': 'toolong' * 10},
            5,
          ],
          'disabled': [
            {'mods': ['ALT'], 'key': 'F4', 'where': 'org.gnome.desktop.wm.keybindings:close', 'description': 7},
            {'key': 'x'},
          ],
        },
        'b': {'launch': 'notalist', 'shortcuts': [{'key': 'b'}]},
        'c': {
          'launch': ['c'],
          'shortcuts': [{'mods': ['SUPER'], 'key': 'code:38', 'then': 'n', 'action': 'new-window'}],
        },
        'd': {'name': 'Ünïcode ${'x' * 130}', 'launch': ['d'], 'shortcuts': [{'mods': ['SUPER'], 'key': 'D'}]},
      },
      'applied': [
        {'where': 'org.gnome.shell.keybindings:toggle-overview', 'accel': '<Super>s'},
        {'where': 'bad', 'accel': '<Super>s'},
        {'where': 'custom:${base}custom0/', 'accel': '<Hyper>x'},
        'x',
      ],
    },
  ],
  'hypr_states': [
    null,
    {'apps': 5},
    {
      'apps': {
        'a': {
          'name': 'A',
          'launch': ['x'],
          'shortcuts': [
            {'mods': ['SUPER'], 'key': 'code:38', 'then': 'n', 'action': 'new-window', 'replaces': 3},
            {'mods': ['SUPER'], 'key': 'x', 'then': 'bad key!'},
            {'mods': ['SUPER'], 'key': 'y', 'then': ''},
          ],
          'disabled': [{'mods': ['SUPER'], 'key': 'Q', 'description': 'Close', 'source': 'Omarchy'}],
        },
        'plugin:ubruckhaus.simple-launcher-for-fools': {
          'name': 'Simple Launcher',
          'launch': ['/x/launcher-toggle'],
          'shortcuts': [{'mods': ['SUPER'], 'key': 'space'}],
        },
      },
    },
  ],
  'cosmic_texts': [
    '{\n    (modifiers: [Super], key: "t"): System(Terminal),\n}\n',
    '// head\n{ /* a */ (modifiers: [Super, Alt], key: "e", description: Some("Ed:it, \\"x\\"")): Spawn("a, b: c"),\n'
        '  // between\n  (modifiers: [], key: "Print"): System(Screenshot)\n} // tail\n',
    '[]',
    '{ (modifiers: [Super], key: "t"): Spawn("x)',
    '{}',
  ],
  'cosmic': {
    'custom': '{\n    // my own\n    (modifiers: [Super, Alt], key: "e", description: Some("Editor")): Spawn("gedit"),\n'
        '    (modifiers: [Super], key: "2"): Disable,\n}\n',
    'defaults': '{\n    (modifiers: [Super], key: "t"): System(Terminal),\n    (modifiers: [Super], key: "1"): Workspace(1),\n'
        '    (modifiers: [Super, Shift], key: "f"): System(WebBrowser),\n    (modifiers: [Super], key: "Left"): Focus(Left),\n}\n',
    'states': [
      {
        'apps': {
          ff: {
            'name': 'Firefox',
            'launch': [ff],
            'shortcuts': [
              {
                'mods': ['SUPER', 'SHIFT'], 'key': 'F', 'replaces': 'Web Browser',
                'taken_from': 'cosmic.shortcuts:super-shift-f', 'action': '',
              },
              {'mods': ['SUPER'], 'key': 'Left', 'replaces': '', 'taken_from': '', 'action': 'new-window', 'label': 'New Window'},
            ],
            'disabled': [],
          },
          files: {
            'name': 'Files',
            'launch': [files],
            'shortcuts': [],
            'disabled': [
              {'mods': ['SUPER', 'ALT'], 'key': 'E', 'description': 'Editor', 'source': 'Custom', 'where': 'custom:${base}cosmic-super-alt-e/'},
            ],
          },
        },
      },
      {
        'apps': {
          ff: {
            'name': 'Firefox',
            'launch': [ff],
            'shortcuts': [{'mods': ['SUPER', 'ALT'], 'key': 'E', 'replaces': '', 'taken_from': '', 'action': ''}],
            'disabled': [],
          },
        },
      },
      {'apps': {}},
    ],
  },
  'gnome': {
    'db': {
      'bindings': {
        'org.gnome.shell.keybindings': {
          'switch-to-application-1': ['<Super>1'],
          'open-new-window-application-1': ['<Super><Control>1'],
          'switch-to-application-2': ['<Super>2'],
          'toggle-overview': ['<Super>s'],
        },
        'org.gnome.desktop.wm.keybindings': {
          'close': ['<Super>q', '<Alt>F4'],
          'switch-input-source': ['<Super>space', 'XF86Keyboard'],
        },
      },
      'paths': ['${base}custom0/', '${base}gnome-launcher-0/', '${base}gone/'],
      'custom': {
        '${base}custom0/': {'name': 'Files', 'command': 'nautilus --new-window', 'binding': '<Super>e'},
        '${base}gnome-launcher-0/': {'name': 'Old', 'command': 'x', 'binding': '<Super><Alt>o'},
        '${base}other/': {'name': '', 'command': 'firefox --x', 'binding': '<Super>f'},
      },
    },
    'favorites': ['org.gnome.Nautilus.desktop', 'firefox.desktop'],
    'main_mods': ['SUPER', 'SHIFT'],
    'states': [
      {
        'apps': {
          ff: {
            'name': 'Firefox',
            'launch': [ff],
            'shortcuts': [
              {
                'mods': ['SUPER'], 'key': '1', 'replaces': 'Switch to application 1',
                'taken_from': 'org.gnome.shell.keybindings:switch-to-application-1', 'action': '',
              },
              {
                'mods': ['SUPER', 'ALT'], 'key': 'P', 'replaces': '', 'taken_from': '',
                'action': 'new-private-window', 'label': 'New Private Window',
              },
            ],
            'disabled': [],
          },
          files: {
            'name': 'Files',
            'launch': [files],
            'shortcuts': [],
            'disabled': [
              {'mods': ['SUPER'], 'key': 'E', 'description': 'Files', 'source': 'Custom', 'where': 'custom:${base}custom0/'},
            ],
          },
          'btop': {
            'name': 'btop',
            'launch': ['btop'],
            'shortcuts': [{'mods': ['SUPER', 'CTRL'], 'key': 'B', 'replaces': '', 'taken_from': '', 'action': ''}],
            'disabled': [],
          },
        },
      },
      {
        'apps': {
          ff: {
            'name': 'Firefox',
            'launch': [ff],
            'shortcuts': [
              {'mods': ['SUPER', 'ALT'], 'key': 'P', 'replaces': '', 'taken_from': '', 'action': 'new-private-window'},
            ],
            'disabled': [],
          },
        },
      },
      {'apps': {}},
    ],
  },
  'hypr': {
    'live': [
      'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: Return\n\tkeycode: 0\n\tdescription: Terminal\n\tdispatcher: exec\n\targ: x',
      'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: Q\n\tdescription: Close window',
      'bind\n\tmodmask: 65\n\tkey: B\n\tdescription: Browser',
      'bind\n\tmodmask: 73\n\tkey: B\n\tdescription: Browser (private)',
      'bind\n\tmodmask: 64\n\tkey: E\n\tdescription: Files',
      'bind\n\tmodmask: 64\n\tsubmap: resize\n\tkey: L',
      'bind\n\tmodmask: 64\n\tkey: mouse:272',
      'bind\n\tmodmask: 64\n\tkey: SUPER + code:10\n\tdescription: Workspace 1',
      'bind\n\tmodmask: x\n\tkey: Z',
      'bind\n\tmodmask: 65\n\tkey: Y\n\tdescription: YouTube',
    ].join('\n\n'),
    'user': [
      [
        'bindings.lua',
        'o.bind("SUPER + E", "Files", { launch = "nautilus --new-window" })\n'
            'o.bind("SUPER + SHIFT + Y", "YouTube", { webapp = "https://www.youtube.com" })\n'
            'hl.unbind("SUPER + Q") -- free it\n'
            '-- o.bind("SUPER + X", "commented", "x")\n'
            'o.bind("SUPER + ALT + T", { tui = "btop" }, { description = "Top" })\n'
            'o.bind("SUPER + ALT + G", "Private", { launch = "firefox --private-window" })\n',
      ],
      ['simple-launcher-shortcuts.lua', 'o.bind("SUPER + SHIFT + F", "Firefox", { launch = "/usr/share/applications/firefox.desktop" })\n'],
    ],
    'defaults': [
      [
        'applications.lua',
        'o.bind("SUPER + RETURN", "Terminal", { omarchy = "terminal" })\n'
            'o.bind("SUPER + SHIFT + B", "Browser", { omarchy = "browser" })\n'
            'o.bind("SUPER + SHIFT + ALT + B", "Browser (private)", { omarchy = "browser --private" })\n'
            'o.bind("SUPER + Q", "Close window", hl.dsp.window.close())\n',
      ],
    ],
    'lines': ['a -- b', 'x("--") -- y', "x('a\\'--') --", 'plain', '--all'],
    'main_mods': ['SUPER', 'SHIFT'],
    'default_apps': {'terminal': 'Alacritty', 'browser': 'firefox', 'editor': 'nvim'},
    'states': [
      {'apps': {}},
      {
        'apps': {
          ff: {
            'name': 'Firefox',
            'launch': [ff],
            'shortcuts': [
              {'mods': ['SUPER', 'ALT'], 'key': 'F', 'action': '', 'replaces': ''},
              {'mods': ['SUPER', 'ALT'], 'key': 'SPACE', 'then': 'N', 'action': 'new-window'},
              {'mods': ['SUPER', 'ALT'], 'key': 'SPACE', 'then': 'P', 'action': 'new-private-window', 'replaces': 'x'},
            ],
            'disabled': [{'mods': ['SUPER', 'SHIFT'], 'key': 'B', 'description': 'Browser', 'source': 'Omarchy'}],
          },
          'plugin:x.y': {
            'name': 'Plug',
            'launch': ['omarchy-shell', 'shell', 'toggle', 'x.y'],
            'shortcuts': [{'mods': ['SUPER'], 'key': 'code:38'}],
            'disabled': [],
          },
          'btop': {
            'name': 'My "top"\nnew',
            'launch': ['btop', '--a b'],
            'shortcuts': [{'mods': ['SUPER', 'CTRL'], 'key': 'B', 'replaces': 'Old\r"x"'}],
            'disabled': [],
          },
          'bad': {'name': 'Bad', 'launch': [], 'shortcuts': [{'key': 'b'}]},
        },
      },
    ],
  },
};

void main() {
  test('shortcuts equal both references', () async {
    final tmp = Directory.systemTemp.createTempSync('am-sc-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final want = await oracle(['shortcuts'], input: jsonEncode(spec), env: {'HOME': tmp.path}) as Map;
    final got = <String, dynamic>{};
    final cs = spec['combos'] as Map;
    got['make'] = [
      for (final m in cs['make'] as List) [makeCombo(m[0], m[1]), makeCombo(m[0], m[1], then: m[2], codes: true)],
    ];
    got['accels'] = [
      for (final t in cs['accels'] as List)
        if (parseAccelerator(t) case final p?)
          [p, accelerator(p), comboLabel(p), [modmask(p), (p['key'] as String).toLowerCase()]]
        else
          [null, null, null, null],
    ];
    got['hypr'] = [
      for (final t in cs['hypr'] as List)
        if (parseHyprCombo(t) case final p?) [p, comboString(p), comboLabel(p)] else [null, null, null],
    ];
    got['labels'] = [for (final k in cs['keys'] as List) [keyLabel(k), keyLabel(k)]];
    got['collides'] = [for (final pair in cs['pairs'] as List) collides(pair[0], pair[1])];
    got['private'] = [for (final a in apps) privateAction(a)];
    got['gnome_states'] = [for (final d in spec['gnome_states'] as List) cleanGnomeState(roundTrip(d))];
    got['hypr_states'] = [for (final d in spec['hypr_states'] as List) cleanHyprState(roundTrip(d), selfKey: selfKey, selfName: 'App Manager')];
    got['cosmic_parse'] = [
      for (final text in spec['cosmic_texts'] as List)
        () {
          try {
            final (head, entries, tail) = parseCosmicShortcuts(text as String);
            return [head, entries, tail];
          } on FormatException catch (e) {
            return {'error': e.message};
          }
        }(),
    ];

    // COSMIC, step by step, with the reference's tag and prefix.
    final cosmic = spec['cosmic'] as Map;
    final dir = Directory(p.join(tmp.path, 'cosmic'))..createSync();
    File(p.join(dir.path, 'custom')).writeAsStringSync(cosmic['custom'] as String);
    final defaults = File(p.join(tmp.path, 'defaults'))..writeAsStringSync(cosmic['defaults'] as String);
    final takenFile = File(p.join(tmp.path, 'taken.json'));
    final stateFile = File(p.join(tmp.path, 'cosmic-state.json'));
    final steps = [];
    for (final state in cosmic['states'] as List) {
      final settings = CosmicSettings(
        customFile: p.join(dir.path, 'custom'),
        defaultsFile: defaults.path,
        readTaken: () => takenFile.existsSync() ? jsonDecode(takenFile.readAsStringSync()) : null,
        writeTaken: (data) => takenFile.writeAsStringSync(jsonEncode(data)),
        writeText: (path, text) => File(path).writeAsStringSync(text),
        ownTag: ' (Launcher)',
        ownPrefix: 'gnome-launcher-',
      );
      final desktopBinds = await readDesktopBinds(settings);
      final customBinds = await readCustomBinds(settings, 'gnome-launcher-');
      final previous = cleanGnomeState(stateFile.existsSync() ? jsonDecode(stateFile.readAsStringSync()) : null);
      final saved = await applyGnome(
        roundTrip(state) as Map<String, dynamic>,
        settings,
        previousApplied: [for (final a in previous['applied'] as List) a as Map],
        ownPrefix: 'gnome-launcher-',
        command: commandOf,
      );
      stateFile.writeAsStringSync(jsonEncode(saved));
      steps.add({
        'desktop': desktopBinds,
        'custom': customBinds,
        'file': File(p.join(dir.path, 'custom')).readAsStringSync(),
        'taken': jsonDecode(takenFile.readAsStringSync()),
        'state': saved,
      });
    }
    got['cosmic_steps'] = steps;

    // GNOME on the fake.
    final gnome = spec['gnome'] as Map;
    final fake = FakeKeySettings(roundTrip(gnome['db']) as Map<String, dynamic>);
    Map<String, dynamic>? saved;
    final gsteps = [];
    for (final state in gnome['states'] as List) {
      final clean = cleanGnomeState(roundTrip(saved));
      final bindings = GnomeBindings(
        clean,
        desktop: await readDesktopBinds(fake),
        custom: await readCustomBinds(fake, 'gnome-launcher-'),
        favorites: [...gnome['favorites'] as List<String>],
        mainMods: [...gnome['main_mods'] as List<String>],
      );
      gsteps.add(answers(bindings, apps, queries));
      saved = await applyGnome(
        roundTrip(state) as Map<String, dynamic>,
        fake,
        previousApplied: [for (final a in clean['applied'] as List) a as Map],
        ownPrefix: 'gnome-launcher-',
        command: commandOf,
      );
      gsteps.add({'db': roundTrip(fake.db), 'state': saved});
    }
    got['gnome_steps'] = gsteps;

    // Hyprland.
    final h = spec['hypr'] as Map;
    final live = parseLiveBinds(h['live'] as String);
    got['live'] = live;
    List<(String, String)> pairs(List list) {
      final sorted = [for (final x in list) (x[0] as String, x[1] as String)]..sort((a, b) => a.$1.compareTo(b.$1));
      return sorted;
    }

    final user = parseUserBinds(pairs(h['user'] as List));
    final defaultBinds = parseUserBinds(pairs(h['defaults'] as List)).$1;
    got['user'] = [
      user.$1,
      [
        for (final id in user.$2) [int.parse(id.split('|')[0]), id.split('|')[1], id.split('|')[2]],
      ]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b))),
    ];
    got['defaults'] = defaultBinds;
    got['strip'] = [for (final line in h['lines'] as List) stripLuaComment(line as String)];
    final hb = [];
    for (final data in h['states'] as List) {
      final state = cleanHyprState(roundTrip(data), selfKey: selfKey, selfName: 'App Manager');
      final bindings = HyprBindings(
        state,
        live: live,
        user: user,
        defaultBinds: defaultBinds,
        mainMods: [...h['main_mods'] as List<String>],
        defaultApps: {...h['default_apps'] as Map<String, String>},
      );
      hb.add(answers(bindings, apps, queries, gnome: false));
      hb.add(renderLua(state, (path) => path, names: LuaNames.reference));
    }
    got['hypr_bindings'] = hb;

    // The plugin calls the desktop's own level "omarchy"; the port says "desktop" everywhere.
    for (final step in want['hypr_bindings'] as List) {
      if (step is Map) {
        for (final answer in step['classify'] as List) {
          if (answer[0] == 'omarchy') answer[0] = levelDesktop;
        }
      }
    }
    for (final key in want.keys) {
      expect(roundTrip(got[key]), want[key], reason: key as String);
    }
    expect(got.keys.toSet(), want.keys.toSet());
  });
}
