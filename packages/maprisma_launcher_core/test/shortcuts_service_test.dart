/// The shortcut routes per desktop with a temporary HOME and fake programs
/// on PATH: a `gsettings` that keeps its keys in a JSON file and logs every
/// call, a COSMIC config folder, a Hyprland config with a fake `hyprctl`.
/// Nothing reaches the real dconf, ~/.config or the running Hyprland.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const base = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/';

/// A gsettings with the program's commands over db.json; calls go to calls.log.
const fakeGsettings = r'''#!/usr/bin/python3 -I
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
db_file = os.path.join(here, "db.json")
db = json.load(open(db_file))
with open(os.path.join(here, "calls.log"), "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
cmd, *args = sys.argv[1:]
RELOC = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
def save():
    json.dump(db, open(db_file, "w"))
if cmd == "list-relocatable-schemas":
    print(RELOC)
elif cmd == "list-schemas":
    print("\n".join(db["schemas"]))
elif cmd == "list-recursively":
    schema = args[0]
    if schema.startswith(RELOC + ":"):
        values = db["custom"].get(schema.split(":", 1)[1], {})
        for key in ("binding", "command", "name"):
            print(f"{RELOC} {key} {values.get(key, chr(39) * 2)}")
    else:
        for key, value in db["keys"].get(schema, {}).items():
            print(f"{schema} {key} {value}")
elif cmd == "get":
    schema, key = args
    if schema.startswith(RELOC + ":"):
        print(db["custom"].get(schema.split(":", 1)[1], {}).get(key, "''"))
    else:
        print(db["keys"].get(schema, {}).get(key, "@as []"))
elif cmd == "set":
    schema, key, value = args
    if schema.startswith(RELOC + ":"):
        db["custom"].setdefault(schema.split(":", 1)[1], {})[key] = value
    else:
        db["keys"].setdefault(schema, {})[key] = value
    save()
elif cmd == "reset":
    schema, key = args
    db["custom"].get(schema.split(":", 1)[1], {}).pop(key, None)
    save()
else:
    sys.exit(1)
''';

/// hyprctl: `binds` prints binds.txt, reload/configerrors are logged;
/// configerrors reports an error once the module has the text of error-on.txt.
const fakeHyprctl = r'''#!/bin/sh
here=$(dirname "$0")
echo "$*" >> "$here/calls.log"
case "$1" in
  binds) cat "$here/binds.txt" ;;
  reload) echo ok ;;
  configerrors)
    if [ -f "$here/error-on.txt" ] && grep -qF "$(cat "$here/error-on.txt")" "$(cat "$here/module.txt")"; then
      echo "line 3: bad bind"
    fi ;;
  *) exit 1 ;;
esac
''';

void writeExec(String path, String text) {
  File(path).writeAsStringSync(text);
  Process.runSync('chmod', ['755', path]);
}

final class Fixture {
  Fixture(String desktop, {Map<String, String> extra = const {}}) {
    home = Directory.systemTemp.createTempSync('am-sc-');
    bin = p.join(home.path, 'bin');
    Directory(bin).createSync();
    // The tools a shortcut command may need, and nothing else of the system.
    for (final tool in ['env', 'sh', 'cat', 'dirname', 'chmod', 'grep']) {
      final found = whichIn(tool, Platform.environment);
      if (found != null) Link(p.join(bin, tool)).createSync(found);
    }
    // The apps' programs: a desktop entry without its program is not listed.
    for (final program in ['firefox', 'nautilus', 'cosmic-term']) {
      writeExec(p.join(bin, program), '#!/bin/sh\n');
    }
    final apps = p.join(home.path, 'data/applications');
    Directory(apps).createSync(recursive: true);
    File(p.join(apps, 'firefox.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox %u\n'
      'Actions=new-private-window;\n[Desktop Action new-private-window]\nName=New Private Window\n'
      'Exec=firefox --private-window %u\n',
    );
    File(p.join(apps, 'files.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=Files\nExec=nautilus --new-window\nPath=${home.path}\n',
    );
    env = {
      'HOME': home.path,
      'PATH': bin,
      'XDG_DATA_HOME': p.join(home.path, 'data'),
      'XDG_DATA_DIRS': p.join(home.path, 'none'),
      'XDG_CONFIG_HOME': p.join(home.path, '.config'),
      'MAPRISMA_LAUNCHER_DESKTOP': desktop,
      ...extra,
    };
    core = CoreService(environment: env);
  }

  late final Directory home;
  late final String bin;
  late final Map<String, String> env;
  late final CoreService core;
  String get firefox => p.join(home.path, 'data/applications/firefox.desktop');
  String get files => p.join(home.path, 'data/applications/files.desktop');

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final reply = jsonDecode(
      await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})),
    ) as Map;
    if (reply['error'] case final Map e) throw ServiceError('${e['code']}', e['message'] as String?);
    return Map<String, dynamic>.from(reply['result'] as Map);
  }

  Future<String> code(String method, Map<String, dynamic> params) async {
    try {
      await call(method, params);
      return 'ok';
    } on ServiceError catch (e) {
      return e.code;
    }
  }

  void dispose() => home.deleteSync(recursive: true);
}

Map<String, dynamic> level(Map state, String key) =>
    (state['keys'] as List).cast<Map<String, dynamic>>().firstWhere((k) => k['key'] == key);

void main() {
  group('GNOME through a fake gsettings', () {
    late Fixture f;
    late File db;
    Map<String, dynamic> read() => jsonDecode(db.readAsStringSync()) as Map<String, dynamic>;

    setUp(() async {
      f = Fixture('gnome');
      writeExec(p.join(f.bin, 'gsettings'), fakeGsettings);
      db = File(p.join(f.bin, 'db.json'))
        ..writeAsStringSync(
          jsonEncode({
            'schemas': ['org.gnome.shell.keybindings', 'org.gnome.settings-daemon.plugins.media-keys', 'org.gnome.shell'],
            'keys': {
              'org.gnome.shell.keybindings': {
                'switch-to-application-1': "['<Super>1']",
                'toggle-overview': "['<Super>s']",
                'show-screenshot-ui': '@as []',
                'some-flag': 'true',
              },
              'org.gnome.settings-daemon.plugins.media-keys': {'custom-keybindings': "['${base}custom0/']"},
              'org.gnome.shell': {'favorite-apps': "['firefox.desktop']"},
            },
            'custom': {
              '${base}custom0/': {'name': "'Files'", 'command': "'nautilus --new-window'", 'binding': "'<Super>e'"},
            },
          }),
        );
      await f.call('apps.list');
    });
    tearDown(() => f.dispose());

    test('state: owners, external shortcuts, Dash keys', () async {
      final state = await f.call('shortcuts.state', {'key': f.firefox, 'mods': ['SUPER'], 'fresh': true});
      expect(state['available'], isTrue);
      expect(state['desktop'], 'GNOME');
      expect(level(state, '1')['level'], 'same'); // Super + 1 opens Firefox already (Dash)
      expect(level(state, 'E'), containsPair('level', 'custom'));
      expect(level(state, 'E')['owner'], 'Files');
      expect(level(state, 'S')['owner'], 'Toggle overview');
      expect(level(state, 'Z')['level'], 'free');
      expect((state['shortcuts'] as List).single, containsPair('file', 'GNOME'));
      final files = await f.call('shortcuts.state', {'key': f.files, 'mods': <String>[]});
      expect((files['shortcuts'] as List).single, containsPair('source', 'external'));
      expect(files['suggestions'], isNotEmpty);
    });

    test('assign takes a GNOME key, remove gives it back', () async {
      await f.call('shortcuts.set', {'key': f.files, 'mods': ['SUPER'], 'combo_key': 's'});
      var data = read();
      expect(data['keys']['org.gnome.shell.keybindings']['toggle-overview'], '[]');
      final own = '${base}maprisma-launcher-0/';
      expect(data['keys']['org.gnome.settings-daemon.plugins.media-keys']['custom-keybindings'], "['${base}custom0/', '$own']");
      expect(data['custom'][own]['binding'], "'<Super>s'");
      expect(data['custom'][own]['name'], "'Files'");
      // The entry's own Exec, in its Path, quoted for GLib and sh alike.
      expect(data['custom'][own]['command'], "'${shlexJoin([p.join(f.bin, 'env'), '-C', f.home.path, 'nautilus', '--new-window'])}'");
      final saved = jsonDecode(File(p.join(f.home.path, '.config/maprisma-launcher/shortcuts.json')).readAsStringSync());
      expect(saved['applied'], [{'where': 'org.gnome.shell.keybindings:toggle-overview', 'accel': '<Super>s'}]);
      final state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER'], 'fresh': true});
      expect(level(state, 'S')['level'], 'same');
      expect((state['shortcuts'] as List).first, containsPair('replaces', 'Toggle overview'));

      await f.call('shortcuts.remove', {'key': f.files, 'combo': {'mods': ['SUPER'], 'key': 'S'}});
      data = read();
      expect(data['keys']['org.gnome.shell.keybindings']['toggle-overview'], "['<Super>s']");
      expect(data['keys']['org.gnome.settings-daemon.plugins.media-keys']['custom-keybindings'], "['${base}custom0/']");
      expect(data['custom'][own], isEmpty); // reset
      // Every call was argv: no shell anywhere.
      final calls = File(p.join(f.bin, 'calls.log')).readAsLinesSync().map((l) => jsonDecode(l) as List);
      expect(calls.every((c) => const {'list-relocatable-schemas', 'list-schemas', 'list-recursively', 'get', 'set', 'reset'}.contains(c.first)), isTrue);
    });

    test('an action, turning off and on a custom shortcut', () async {
      await f.call('shortcuts.set', {
        'key': f.firefox, 'mods': ['SUPER', 'ALT'], 'combo_key': 'P', 'action': 'new-private-window',
      });
      final data = read();
      final own = '${base}maprisma-launcher-0/';
      expect(data['custom'][own]['name'], "'Firefox: New Private Window'");
      expect(data['custom'][own]['command'], "'firefox --private-window'");

      await f.call('shortcuts.disable', {'key': f.files, 'combo': {'mods': ['SUPER'], 'key': 'E'}});
      expect(read()['custom']['${base}custom0/']['binding'], "''");
      var state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER']});
      expect((state['disabled'] as List).single, containsPair('source', 'Custom'));
      expect(level(state, 'E')['level'], 'free');
      await f.call('shortcuts.restore', {'key': f.files, 'combo': {'mods': ['SUPER'], 'key': 'E'}});
      expect(read()['custom']['${base}custom0/']['binding'], "'<Super>e'");
      state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER']});
      expect(state['disabled'], isEmpty);
    });

    test('changing a shortcut and moving a key between apps', () async {
      await f.call('shortcuts.set', {'key': f.firefox, 'mods': ['SUPER', 'ALT'], 'combo_key': 'F'});
      // Change Super + Alt + F to Super + Alt + G.
      await f.call('shortcuts.set', {
        'key': f.firefox, 'mods': ['SUPER', 'ALT'], 'combo_key': 'G',
        'editing': {'mods': ['SUPER', 'ALT'], 'key': 'F'},
      });
      var labels = await f.call('shortcuts.labels');
      expect(labels['labels'], {f.firefox: ['Super + Alt + G']});
      final state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER', 'ALT']});
      expect(level(state, 'G'), containsPair('level', 'launcher'));
      await f.call('shortcuts.set', {'key': f.files, 'mods': ['SUPER', 'ALT'], 'combo_key': 'G'});
      labels = await f.call('shortcuts.labels');
      expect(labels['labels'], {f.files: ['Super + Alt + G']});
      // The same again: nothing to do.
      expect(await f.code('shortcuts.set', {'key': f.files, 'mods': ['SUPER', 'ALT'], 'combo_key': 'G'}), 'refused');
    });

    test('only the fixed keys, modifiers and actions', () async {
      for (final params in [
        {'key': f.files, 'mods': ['SUPER'], 'combo_key': 'a;rm -rf'},
        {'key': f.files, 'mods': ['SUPER'], 'combo_key': 'XF86AudioPlay'},
        {'key': f.files, 'mods': ['HYPER'], 'combo_key': 'A'},
        {'key': f.files, 'mods': <String>[], 'combo_key': 'A'},
        {'key': f.firefox, 'mods': ['SUPER'], 'combo_key': 'A', 'action': 'no-such-action'},
        {'key': f.firefox, 'mods': 'SUPER', 'combo_key': 'A'},
      ]) {
        expect(await f.code('shortcuts.set', params), 'bad_params', reason: '$params');
      }
      expect(await f.code('shortcuts.set', {'key': '/nope.desktop', 'mods': ['SUPER'], 'combo_key': 'A'}), 'unknown_app');
      expect(await f.code('shortcuts.remove', {'key': f.files, 'combo': {'mods': ['SUPER'], 'key': 'Q'}}), 'not_found');
    });

    test('default modifiers', () async {
      expect((await f.call('shortcuts.state', {'key': f.files}))['default_mods'], ['SUPER', 'SHIFT']);
      expect((await f.call('shortcuts.default_mods', {'mods': ['ALT', 'SUPER']}))['default_mods'], ['SUPER', 'ALT']);
      expect((await f.call('shortcuts.default_mods', {'mods': <String>[]}))['default_mods'], ['SUPER', 'SHIFT']);
    });
  });

  group('COSMIC shortcut file', () {
    late Directory home;
    late ShortcutService service;
    late String custom;
    final apps = <String, Map>{};

    setUp(() {
      home = Directory.systemTemp.createTempSync('am-cosmic-');
      final config = p.join(home.path, '.config');
      custom = p.join(config, 'cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom');
      Directory(p.dirname(custom)).createSync(recursive: true);
      File(custom).writeAsStringSync(
        '{\n    // mine\n    (modifiers: [Super, Alt], key: "e", description: Some("Editor")): Spawn("gedit"),\n}\n',
      );
      final defaults = File(p.join(home.path, 'defaults'))
        ..writeAsStringSync('{\n    (modifiers: [Super], key: "t"): System(Terminal),\n}\n');
      final apps0 = p.join(home.path, 'apps');
      Directory(apps0).createSync();
      final desktopFile = p.join(apps0, 'term.desktop');
      File(desktopFile).writeAsStringSync('[Desktop Entry]\nType=Application\nName=Term\nExec=cosmic-term\n');
      apps['term'] = {'desktop_path': desktopFile, 'desktop_id': 'term', 'name': 'Term', 'exec': 'cosmic-term', 'actions': []};
      final session = Session(environment: {'HOME': home.path, 'XDG_CONFIG_HOME': config, 'PATH': '/nonexistent'});
      final store = ConfigStore(session);
      service = ShortcutService(backendFor(CosmicDesktop(session), store, cosmicDefaults: defaults.path), store);
    });
    tearDown(() => home.deleteSync(recursive: true));

    test('take a default key, keep the user entries, give it back', () async {
      final app = apps['term']!;
      final state = await service.view(app, {'mods': ['SUPER'], 'fresh': true});
      expect(state['desktop'], 'COSMIC');
      expect(level(state, 'T'), containsPair('owner', 'Terminal'));
      await service.assign(app, {'mods': ['SUPER'], 'combo_key': 'T'});
      final text = File(custom).readAsStringSync();
      expect(text, contains('// mine'));
      expect(text, contains('(modifiers: [Super, Alt], key: "e", description: Some("Editor")): Spawn("gedit")'));
      // One entry per key: the launcher's replaces COSMIC's default there.
      expect(text, isNot(contains('System(Terminal)')));
      expect(text, contains('description: Some("Term (Maprisma Launcher)")): Spawn("cosmic-term")'));
      expect(parseCosmicShortcuts(text).$2, hasLength(2));
      // Ask AI's facts: the keys that open each app.
      expect(await service.allLabels({'k': app}), {'k': ['Super + T']});
      await service.remove(app, {'combo': {'mods': ['SUPER'], 'key': 'T'}});
      expect(await service.allLabels({'k': app}), isEmpty);
      expect(File(custom).readAsStringSync(), '{\n    // mine\n    (modifiers: [Super, Alt], key: "e", description: Some("Editor")): Spawn("gedit"),\n}\n');
    });

    test('a file COSMIC could not read is never rewritten', () async {
      File(custom).writeAsStringSync('{ (modifiers: [Super], key: "t"): Spawn("x)');
      final app = apps['term']!;
      expect(() => service.assign(app, {'mods': ['SUPER'], 'combo_key': 'Y'}), throwsA(isA<Object>()));
      expect(File(custom).readAsStringSync(), '{ (modifiers: [Super], key: "t"): Spawn("x)');
    });
  });

  test('a COSMIC shortcut file that is a FIFO or too large: read-only, no hang', () {
    final home = Directory.systemTemp.createTempSync('am-cosmic-fifo-');
    addTearDown(() => home.deleteSync(recursive: true));
    final config = p.join(home.path, '.config');
    final custom = p.join(config, 'cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom');
    Directory(p.dirname(custom)).createSync(recursive: true);
    expect(Process.runSync('mkfifo', [custom]).exitCode, 0);
    final session = Session(environment: {'HOME': home.path, 'XDG_CONFIG_HOME': config, 'PATH': '/nonexistent'});
    final store = ConfigStore(session);
    expect(backendFor(CosmicDesktop(session), store, cosmicDefaults: p.join(home.path, 'none')), isNull);
    File(custom).deleteSync();
    File(custom).writeAsStringSync('{\n${'    // x\n' * 200000}}\n');
    expect(backendFor(CosmicDesktop(session), store, cosmicDefaults: p.join(home.path, 'none')), isNull);
  });

  group('Omarchy with a fake hyprctl', () {
    late Fixture f;
    late String hypr;
    setUp(() async {
      final omarchy = Directory.systemTemp.createTempSync('am-omarchy-');
      Directory(p.join(omarchy.path, 'default/hypr/bindings')).createSync(recursive: true);
      File(p.join(omarchy.path, 'default/hypr/bindings/apps.lua'))
          .writeAsStringSync('o.bind("SUPER + RETURN", "Terminal", { omarchy = "terminal" })\n');
      f = Fixture('omarchy', extra: {'OMARCHY_PATH': omarchy.path});
      addTearDown(() => omarchy.deleteSync(recursive: true));
      writeExec(p.join(f.bin, 'hyprctl'), fakeHyprctl);
      File(p.join(f.bin, 'binds.txt')).writeAsStringSync(
        'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: Return\n\tdescription: Terminal\n\n'
        'bind\n\tmodmask: 64\n\tsubmap: \n\tkey: E\n\tdescription: Files\n',
      );
      hypr = p.join(f.home.path, '.config/hypr');
      Directory(hypr).createSync(recursive: true);
      File(p.join(hypr, 'hyprland.lua')).writeAsStringSync('require("hypr.bindings")\n');
      File(p.join(hypr, 'bindings.lua'))
          .writeAsStringSync('o.bind("SUPER + E", "Files", { launch = "nautilus --new-window" })\n');
      await f.call('apps.list');
    });
    tearDown(() => f.dispose());

    test('render, require once, reload; owners from binds and files', () async {
      var state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER'], 'fresh': true});
      expect(state['desktop'], 'Omarchy');
      expect(level(state, 'Return'), containsPair('level', 'desktop'));
      expect(level(state, 'E'), containsPair('level', 'same')); // the user's own bind opens Files
      expect((state['shortcuts'] as List).single, containsPair('file', 'bindings.lua'));

      await f.call('shortcuts.set', {'key': f.firefox, 'mods': ['SUPER'], 'combo_key': 'Return'});
      final lua = File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).readAsStringSync();
      expect(lua, contains('-- Firefox (replaces: Terminal)\nhl.unbind("SUPER + Return")\n'
          'o.bind("SUPER + Return", "Firefox", { launch = "${f.firefox}" })'));
      expect(lua, isNot(contains('capture')));
      final main = File(p.join(hypr, 'hyprland.lua')).readAsStringSync();
      expect(main, endsWith('require("hypr.maprisma-launcher-shortcuts")\n'));
      expect(File(p.join(hypr, 'hyprland.lua.before-maprisma-launcher-shortcuts')).readAsStringSync(),
          'require("hypr.bindings")\n');
      await f.call('shortcuts.set', {'key': f.firefox, 'mods': ['SUPER', 'ALT'], 'combo_key': 'P', 'action': 'new-private-window'});
      expect(RegExp('maprisma-launcher-shortcuts').allMatches(File(p.join(hypr, 'hyprland.lua')).readAsStringSync()), hasLength(1));
      expect(File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).readAsStringSync(),
          contains('{ launch = "${f.firefox}:new-private-window" }'));
      final calls = File(p.join(f.bin, 'calls.log')).readAsLinesSync();
      expect(calls.where((c) => c == 'reload'), isNotEmpty);
      expect(calls.toSet(), {'binds', 'reload', 'configerrors'});

      // Turning off the user's own bind for Files: an unbind in the module.
      await f.call('shortcuts.disable', {'key': f.files, 'combo': {'mods': ['SUPER'], 'key': 'E'}});
      expect(File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).readAsStringSync(),
          contains('-- Files: disabled (was: Files)\nhl.unbind("SUPER + E")'));
      state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER']});
      expect((state['disabled'] as List).single, containsPair('source', 'bindings.lua'));
    });

    test('a new configuration error restores the files', () async {
      await f.call('shortcuts.set', {'key': f.firefox, 'mods': ['SUPER', 'ALT'], 'combo_key': 'F'});
      final before = File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).readAsStringSync();
      // The fake runs with the test's own environment: it is told where the module is.
      File(p.join(f.bin, 'module.txt')).writeAsStringSync(p.join(hypr, 'maprisma-launcher-shortcuts.lua'));
      File(p.join(f.bin, 'error-on.txt')).writeAsStringSync('"Files"');
      expect(await f.code('shortcuts.set', {'key': f.files, 'mods': ['SUPER', 'ALT'], 'combo_key': 'N'}), 'not_applied');
      expect(File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).readAsStringSync(), before);
      expect((await f.call('shortcuts.labels'))['labels'], {f.firefox: ['Super + Alt + F']});
    });

    test('a configuration error that was there before is not ours: the first shortcut still saves', () async {
      File(p.join(hypr, 'hyprland.lua')).writeAsStringSync('require("hypr.bindings")\n-- broken already\n');
      File(p.join(f.bin, 'module.txt')).writeAsStringSync(p.join(hypr, 'hyprland.lua'));
      File(p.join(f.bin, 'error-on.txt')).writeAsStringSync('broken already');
      expect(File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).existsSync(), isFalse);
      await f.call('shortcuts.set', {'key': f.firefox, 'mods': ['SUPER', 'ALT'], 'combo_key': 'F'});
      expect(File(p.join(hypr, 'maprisma-launcher-shortcuts.lua')).readAsStringSync(), contains('"Firefox"'));
      expect((await f.call('shortcuts.labels'))['labels'], {f.firefox: ['Super + Alt + F']});
    });

    test('desktop files without a valid id go through a private link', () async {
      final backend = HyprBackend(Session(environment: f.env), f.core.store);
      final odd = p.join(f.home.path, 'Google Maps.desktop');
      File(odd).writeAsStringSync('[Desktop Entry]\n');
      final alias = backend.desktopArg(odd);
      expect(p.basename(alias), 'Google-Maps.desktop');
      expect(Link(alias).targetSync(), odd);
      expect(backend.desktopArg(odd), alias);
      expect(backend.desktopArg(f.firefox), f.firefox);
    });
  });

  test('generic desktops are read-only', () async {
    final f = Fixture('generic');
    addTearDown(f.dispose);
    await f.call('apps.list');
    final state = await f.call('shortcuts.state', {'key': f.files, 'mods': ['SUPER']});
    expect(state['available'], isFalse);
    expect(await f.code('shortcuts.set', {'key': f.files, 'mods': ['SUPER'], 'combo_key': 'A'}), 'not_available');
  });
}
