/// Maprisma's shared helpers catalog and the shared helper choice of all
/// Maprisma apps (maprisma-ai/settings.json). Scratch folders only: no real
/// config is read or written.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/helpers_shipped.g.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A scratch folder: a home, a fake bin folder (the only PATH) and a root for system files.
final class World {
  World._(this.dir);
  final String dir;
  static World create() {
    final w = World._(Directory.systemTemp.createTempSync('maprisma-launcher-helpers-').path);
    for (final d in [w.home, w.root, w.fakeBin]) {
      Directory(d).createSync(recursive: true);
    }
    return w;
  }

  String get home => p.join(dir, 'home');
  String get root => p.join(dir, 'root');
  String get fakeBin => p.join(dir, 'fakebin');
  String get config => p.join(dir, 'config');
  String get shared => p.join(config, 'maprisma-ai/settings.json');

  Session session([Map<String, String> extra = const {}]) =>
      Session(environment: {'HOME': home, 'PATH': '$fakeBin:/usr/bin:/bin', 'XDG_CONFIG_HOME': config, ...extra});

  void writeFile(String path, String text, {String? mode}) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    if (mode != null) Process.runSync('chmod', [mode, path]);
  }

  void fake(String name, String body) => writeFile(p.join(fakeBin, name), '#!/bin/sh\n$body\n', mode: '755');
  void dispose() => Directory(dir).deleteSync(recursive: true);
}

String catalogText(int version, List<Object?> helpers) => jsonEncode({'version': version, 'helpers': helpers});

Map<String, Object?> entry(String id, {List<Object?>? argv, bool stdin = false, bool verified = false, Object? ask = const {}}) => {
  'id': id,
  'name': id.toUpperCase(),
  'command': id,
  'ask': ask == null ? null : {'argv': argv ?? [id, '-p', '{prompt}'], 'stdin': stdin},
  'task': {'argv': [id, '{prompt}']},
  'verified': verified,
};

void main() {
  final root = Directory.current.path.endsWith('maprisma_launcher_core') ? '.' : 'packages/maprisma_launcher_core';
  late World w;
  late String saved;
  setUp(() {
    w = World.create();
    saved = systemHelpersCatalog;
    systemHelpersCatalog = p.join(w.root, 'usr/lib/maprisma/data/helpers.json');
  });
  tearDown(() {
    systemHelpersCatalog = saved;
    w.dispose();
  });

  group('catalog', () {
    test('the shipped catalog is data/helpers.json, built in; Claude Code first', () {
      expect(jsonDecode(shippedHelpersJson), jsonDecode(File('$root/data/helpers.json').readAsStringSync()),
          reason: 'run tools/gen-helpers');
      final ids = [for (final h in shippedHelpersCatalog.helpers) h.id];
      expect(ids.take(2), ['claude', 'codex']);
      expect(ids, containsAll(['agy', 'cursor-agent', 'copilot', 'hermes', 'pi']));
      expect(ids, isNot(contains('gemini')), reason: 'interactive only: its tools stay on in one-shot mode');
      expect(ids, isNot(contains('opencode')), reason: 'no ask');
    });

    test('parse: broken entries and repeated ids are left out; not a catalog is null', () {
      final c = parseHelpersCatalog(catalogText(3, [
        entry('good', verified: true),
        entry('noask', ask: null),
        entry('../evil'),
        {'id': 'path', 'command': '/bin/sh', 'ask': {'argv': ['/bin/sh', '{prompt}']}},
        entry('noprompt', argv: ['noprompt', '-p']),
        entry('other', argv: ['sh', '-c', '{prompt}']),
        entry('piped', argv: ['piped', '-'], stdin: true),
        {'id': 'good', 'command': 'again', 'ask': {'argv': ['again', '{prompt}']}},
        'garbage',
      ]))!;
      expect(c.version, 3);
      expect([for (final h in c.helpers) h.id], ['good', 'piped']);
      expect(c.helpers[0].verified, isTrue);
      expect(c.helpers[1].verified, isFalse);
      for (final bad in ['', '[]', '{}', '{"version": "1", "helpers": []}', '{"version": 1}']) {
        expect(parseHelpersCatalog(bad), isNull, reason: bad);
      }
    });

    test("Maprisma's installed catalog wins when it parses and is at least as new", () {
      final shipped = shippedHelpersCatalog;
      expect(helpersCatalog().version, shipped.version);
      w.writeFile(systemHelpersCatalog, catalogText(shipped.version, [entry('newer')]));
      expect([for (final h in helpersCatalog().helpers) h.id], ['newer']);
      w.writeFile(systemHelpersCatalog, catalogText(shipped.version + 1, [entry('newest')]));
      expect([for (final h in helpersCatalog().helpers) h.id], ['newest']);
      w.writeFile(systemHelpersCatalog, catalogText(shipped.version - 1, [entry('older')]));
      expect(helpersCatalog().helpers.first.id, 'claude', reason: 'older: the shipped one');
      w.writeFile(systemHelpersCatalog, 'not json {');
      expect(helpersCatalog().helpers.first.id, 'claude', reason: 'broken: the shipped one');
    });

    test('detection: PATH, ~/.local/bin, else mise which for a command with a shim', () async {
      final env = {'PATH': w.fakeBin};
      expect(await findHelperCommand('agy', w.home, env), isNull);
      final agy = p.join(w.dir, 'mise-installs/agy');
      w.writeFile(agy, '#!/bin/sh\n', mode: '755');
      w.fake('mise', '[ "\$1" = which ] && [ "\$2" = agy ] && echo "$agy" && exit 0\nexit 1');
      expect(await findHelperCommand('agy', w.home, env), isNull, reason: 'no shim: mise is not asked');
      w.writeFile(p.join(w.home, '.local/share/mise/shims/agy'), '', mode: '755');
      expect(await findHelperCommand('agy', w.home, env), agy);
      w.writeFile(p.join(w.home, '.local/bin/copilot'), '#!/bin/sh\n', mode: '755');
      expect(await findHelperCommand('copilot', w.home, env), p.join(w.home, '.local/bin/copilot'));
      expect(await findHelperCommand('../x', w.home, env), isNull);
    });

    test("the helpers: catalog order; the Launcher's own five keep their stricter setups", () {
      final list = helpersFrom(shippedHelpersCatalog);
      final ids = [for (final h in list) h.command];
      expect(ids.take(4), ['claude', 'codex', 'agy', 'cursor-agent']);
      expect(ids, isNot(contains('gemini')), reason: 'no one-shot ask in catalog version 2');
      for (final id in ['claude', 'codex', 'agy', 'pi', 'hermes']) {
        final own = list.firstWhere((h) => h.command == id);
        expect(own.catalog, isNull, reason: id);
        expect(own.verified, isTrue, reason: id);
      }
      expect(list.firstWhere((h) => h.command == 'agy').argv, containsAll(['--mode', 'plan', '--sandbox']));
      expect(list.firstWhere((h) => h.command == 'claude').argv, contains('--disable-slash-commands'));
      final cursor = list.firstWhere((h) => h.command == 'cursor-agent');
      expect(cursor.catalog, isNotNull);
      expect(cursor.verified, isFalse);
      // one of ours missing from a catalog is still offered, last
      final short = helpersFrom(parseHelpersCatalog(catalogText(1, [entry('gemini'), entry('codex')]))!);
      expect([for (final h in short) h.command], ['gemini', 'codex', 'claude', 'agy', 'pi', 'hermes']);
    });

    test('states: a catalog agent only when installed, then ready and marked untested', () async {
      w.fake('claude', 'exit 0');
      w.writeFile(p.join(w.home, '.local/bin/cursor-agent'), '#!/bin/sh\n', mode: '755');
      w.writeFile(p.join(w.home, '.local/bin/gemini'), '#!/bin/sh\n', mode: '755');
      final states = {for (final h in await helperStates(w.session({'PATH': w.fakeBin}))) h['command']: h};
      expect(states['cursor-agent']!['installed'], isTrue);
      expect(states['cursor-agent']!['signed_in'], isTrue);
      expect(states['cursor-agent']!['verified'], isFalse);
      expect(states['cursor-agent']!['catalog'], isTrue);
      expect(states['claude']!['signed_in'], isFalse, reason: 'its own sign-in check');
      expect(states['claude']!['verified'], isTrue);
      expect(states['codex']!['installed'], isFalse, reason: 'own helpers are listed when missing');
      expect(states.containsKey('grok'), isFalse, reason: 'catalog helpers only when installed');
      expect(states.containsKey('gemini'), isFalse, reason: 'installed, but no one-shot ask: not offered');
    });

    test('a catalog agent gets the prompt as one argument, not on stdin; stdout is the answer', () async {
      w.fake('cursor-agent', r'''
for a in "$@"; do printf '[%s]' "$a"; done > "$HOME/args"
cat > "$HOME/stdin"
echo "the answer"
''');
      const prompt = '-rf it\'s "odd"\n\$HOME `x`';
      expect(await AskRunner(w.session()).run('cursor-agent', prompt), 'the answer\n');
      expect(File('${w.home}/args').readAsStringSync(), '[-p][--mode][ask][--sandbox][enabled][--output-format][text][ $prompt]');
      expect(File('${w.home}/stdin').readAsStringSync(), '');
    });

    test('a stdin entry gets it on stdin; a prompt too long for one argument is refused', () async {
      w.writeFile(systemHelpersCatalog,
          catalogText(shippedHelpersCatalog.version, [entry('piped', argv: ['piped', '-'], stdin: true), entry('argy')]));
      w.fake('piped', 'cat');
      w.fake('argy', 'echo ran > "\$HOME/ran"');
      expect(await AskRunner(w.session()).run('piped', 'hello'), 'hello');
      await expectLater(AskRunner(w.session()).run('argy', 'x' * (argvPromptMax + 1)), throwsA(isA<StateError>()));
      expect(File('${w.home}/ran').existsSync(), isFalse);
    });
  });

  group('shared choice', () {
    test('missing file: auto, or the old ask_helper; invalid values are auto', () {
      final s = w.session();
      expect(readAiChoice(s), 'auto');
      expect(readAiChoice(s, legacy: 'codex'), 'codex');
      expect(readAiChoice(s, legacy: '--evil'), 'auto');
      expect(readAiChoice(s, legacy: 3), 'auto');
      for (final (text, want) in [
        ('{"helper": "cursor-agent"}', 'cursor-agent'),
        ('{"helper": "pi:llama/gemma-3:4b"}', 'pi:llama/gemma-3:4b'),
        ('{"helper": "auto"}', 'auto'),
        ('{"helper": "-x"}', 'auto'),
        ('{"helper": "a b"}', 'auto'),
        ('{"helper": "${'a' * 162}"}', 'auto'),
        ('{"helper": 7}', 'auto'),
        ('[]', 'auto'),
        ('not json', 'auto'),
      ]) {
        w.writeFile(w.shared, text);
        expect(readAiChoice(s, legacy: 'codex'), want, reason: text);
      }
    });

    test('XDG_CONFIG_HOME unset: ~/.config/maprisma-ai', () {
      expect(aiSettingsDir(Session(environment: {'HOME': w.home})), p.join(w.home, '.config/maprisma-ai'));
      expect(aiSettingsDir(Session(environment: {'HOME': w.home, 'XDG_CONFIG_HOME': ''})), p.join(w.home, '.config/maprisma-ai'));
    });

    test('write: atomic, private, unknown keys kept, invalid values refused', () {
      final s = w.session();
      writeAiChoice(s, 'codex');
      expect(jsonDecode(File(w.shared).readAsStringSync()), {'helper': 'codex'});
      expect(FileStat.statSync(p.dirname(w.shared)).mode & 0x1ff, 0x1c0);
      expect(FileStat.statSync(w.shared).mode & 0x1ff, 0x180);
      w.writeFile(w.shared, '{"helper": "x", "other_app": {"a": 1}, "theme": "dark"}');
      writeAiChoice(s, 'auto');
      expect(jsonDecode(File(w.shared).readAsStringSync()), {'helper': 'auto', 'other_app': {'a': 1}, 'theme': 'dark'});
      expect(readAiChoice(s), 'auto');
      expect(() => writeAiChoice(s, '--evil'), throwsArgumentError);
      expect(() => writeAiChoice(s, ''), throwsArgumentError);
      expect(Directory(p.dirname(w.shared)).listSync().map((e) => p.basename(e.path)), ['settings.json'],
          reason: 'no temporary file left');
    });

    test('resolve: the chosen one when installed, else the first ready, else the first installed', () {
      final states = <Map<String, dynamic>>[
        {'command': 'claude', 'installed': true, 'signed_in': false},
        {'command': 'codex', 'installed': false, 'signed_in': false},
        {'command': 'cursor-agent', 'installed': true, 'signed_in': true},
        {'command': 'pi:l/m', 'installed': true, 'signed_in': true, 'local': true},
      ];
      expect(resolveAiChoice('auto', states), 'cursor-agent');
      expect(resolveAiChoice('claude', states), 'claude');
      expect(resolveAiChoice('pi:l/m', states), 'pi:l/m');
      expect(resolveAiChoice('codex', states), 'cursor-agent', reason: 'not installed: auto');
      expect(resolveAiChoice('nobody', states), 'cursor-agent');
      expect(resolveAiChoice('auto', [states[0]]), 'claude');
      expect(resolveAiChoice('auto', [states[1]]), isNull);
    });

    test('routes: ask.helpers shows the shared choice, ai.helper.set writes it', () async {
      w.fake('claude', 'exit 0');
      w.writeFile(p.join(w.home, '.local/bin/cursor-agent'), '#!/bin/sh\n', mode: '755');
      final core = CoreService(environment: {
        'HOME': w.home,
        'PATH': '${w.fakeBin}:/usr/bin:/bin',
        'XDG_CONFIG_HOME': w.config,
        'XDG_DATA_HOME': p.join(w.dir, 'data'),
        'XDG_DATA_DIRS': p.join(w.dir, 'none'),
        'XDG_STATE_HOME': p.join(w.dir, 'state'),
        'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
      });
      Future<Map> call(String method, [Map<String, dynamic> params = const {}]) async =>
          jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params}))) as Map;

      // The Launcher's old own choice, before the shared file exists.
      w.writeFile(p.join(w.config, 'maprisma-launcher/settings.json'), '{"ask_helper": "claude"}');
      var r = (await call('ask.helpers'))['result'] as Map;
      expect(r['choice'], 'claude');
      expect(r['chosen'], 'claude');
      expect(File(w.shared).existsSync(), isFalse, reason: 'reading writes nothing');

      r = (await call('ai.helper.set', {'helper': 'auto'}))['result'] as Map;
      expect(r['choice'], 'auto');
      expect(r['chosen'], 'cursor-agent', reason: 'the first ready one (claude is not signed in)');
      expect(jsonDecode(File(w.shared).readAsStringSync()), {'helper': 'auto'});

      r = (await call('ai.helper.set', {'helper': 'cursor-agent'}))['result'] as Map;
      expect(r['choice'], 'cursor-agent');
      expect(r['chosen'], 'cursor-agent');
      // Another app picked something this PC doesn't have: auto, file unchanged.
      w.writeFile(w.shared, '{"helper": "grok"}');
      r = (await call('ask.helpers'))['result'] as Map;
      expect(r['choice'], 'grok');
      expect(r['chosen'], 'cursor-agent');
      expect((await call('ai.helper.set', {'helper': '-bad'}))['error']['code'], 'bad_params');
      expect((await call('ai.helper.set', {'helper': 3}))['error']['code'], 'bad_params');
      expect(jsonDecode(File(w.shared).readAsStringSync()), {'helper': 'grok'});
      // An Ask no longer writes the Launcher's own ask_helper.
      expect(jsonDecode(File(p.join(w.config, 'maprisma-launcher/settings.json')).readAsStringSync())['ask_helper'], 'claude');
    });
  });
}
