import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/github_releases.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late Session session;
  late CoreService core;
  File getSettings() => File(sharedAiFile(session));
  void rules(Object? value) {
    getSettings().parent.createSync(recursive: true);
    getSettings().writeAsStringSync(
      jsonEncode({'helper': 'auto', 'ask_ai': value}),
    );
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async => Map<String, dynamic>.from(
    jsonDecode(
      await core.handleAsync(
        jsonEncode({
          'id': 1,
          'protocol': 1,
          'method': method,
          'params': params,
        }),
      ),
    ),
  );
  void executable(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    Process.runSync('/bin/chmod', ['755', path]);
  }

  Future<({String key, String proposal})> propose({
    String action = 'hide',
  }) async {
    executable(
      p.join(home.path, 'bin/claude'),
      r'''#!/bin/sh
prompt=$(/bin/cat)
writer=$(printf '%s' "$prompt" | /bin/sed -n 's/.*"id":"\(a[0-9]*\)","name":"Writer".*/\1/p')
printf '{"action":"ACTION","apps":["%s"]}\n' "$writer"
'''
          .replaceFirst('ACTION', action),
    );
    final list = (await call('apps.list'))['result']['apps'] as List;
    final result = await call('ask.run', {
      'helper': 'claude',
      'request': 'change Writer',
    });
    expect(result['error'], isNull, reason: '$result');
    final key = '${list.firstWhere((app) => app['name'] == 'Writer')['key']}';
    return (key: key, proposal: result['result']['proposals'][key] as String);
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('launcher-rules-');
    session = Session(
      environment: {
        'HOME': home.path,
        'PATH': '${home.path}/bin',
        'XDG_CONFIG_HOME': '${home.path}/config',
        'XDG_STATE_HOME': '${home.path}/state',
        'XDG_DATA_HOME': '${home.path}/data',
        'XDG_DATA_DIRS': '${home.path}/system',
        'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
      },
    );
    File('${home.path}/data/applications/writer.desktop')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '[Desktop Entry]\nType=Application\nName=Writer\nExec=/bin/true\n',
      );
    core = CoreService(session: session);
  });
  tearDown(() {
    core.dispose();
    home.deleteSync(recursive: true);
  });

  test(
    'defaults, every launcher action and source, local folder and malformed values',
    () {
      expect(askAiAllowed(session, 'launcher.install', source: 'aur'), isTrue);
      for (final value in [false, [], 'bad', null]) {
        rules(value);
        expect(readAskAiRules(session).broken, isTrue);
        expect(askAiAllowed(session, 'launcher.hide'), isFalse);
      }
      for (final kind in ['actions', 'sources', 'folders']) {
        for (final value in [[], false, 1, 'false', null]) {
          rules({kind: value});
          expect(readAskAiRules(session).broken, isTrue);
          expect(
            askAiAllowed(session, 'launcher.install', source: 'local'),
            isFalse,
          );
        }
      }
      for (final item in askAiActions.where((a) => a.app == 'launcher')) {
        rules({
          'actions': {item.id: 'true'},
        });
        expect(askAiAllowed(session, item.id), isFalse);
        rules({
          'actions': {item.id: true},
        });
        expect(askAiAllowed(session, item.id), isTrue);
      }
      for (final source in askAiSources) {
        rules({
          'sources': {source.id: false},
        });
        expect(
          askAiAllowed(session, 'launcher.install', source: source.id),
          isFalse,
        );
        expect(askAiAllowed(session, 'launcher.hide'), isTrue);
      }
      rules({
        'folders': {'downloads': false},
        'sources': {'unknown': false},
      });
      expect(
        askAiAllowed(session, 'launcher.install', source: 'local'),
        isFalse,
      );
      expect(
        askAiAllowed(session, 'launcher.install', source: 'github'),
        isTrue,
      );
      for (final level in ['answers', 'bad', false, null]) {
        rules({'level': level});
        expect(askAiAllowed(session, 'launcher.hide'), isFalse);
      }
      rules({});
      expect(askAiAllowed(session, 'launcher.hide'), isTrue);
      for (final contents in ['broken', '[]', ' ' * (65536 + 1)]) {
        getSettings().writeAsStringSync(contents);
        expect(askAiAllowed(session, 'launcher.hide'), isFalse);
      }
      getSettings().deleteSync();
      Directory(getSettings().path).createSync();
      expect(askAiAllowed(session, 'launcher.hide'), isFalse);
    },
  );

  test(
    'helper refuses broken, non-object, oversized and unreadable files without changing them',
    () {
      for (final contents in ['broken', '[]', ' ' * (65536 + 1)]) {
        getSettings().parent.createSync(recursive: true);
        getSettings().writeAsStringSync(contents);
        expect(
          () => writeAiChoice(session, 'claude'),
          throwsA(isA<FileSystemException>()),
        );
        expect(getSettings().readAsStringSync(), contents);
      }
      getSettings().deleteSync();
      Directory(getSettings().path).createSync();
      expect(
        () => writeAiChoice(session, 'claude'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('shared settings reads enforce the byte limit for every consumer', () {
    const json = '{"helper":"claude","web_search":true,"ask_ai":{}}';
    getSettings().parent.createSync(recursive: true);
    getSettings().writeAsStringSync(json.padRight(65536));
    expect(readAiChoice(session), 'claude');
    expect(readAiWebSearch(session), isTrue);
    expect(askAiAllowed(session, 'launcher.hide'), isTrue);
    getSettings().writeAsStringSync(' ', mode: FileMode.append);
    expect(readSharedObject(session), isNull);
    expect(readAiChoice(session), 'auto');
    expect(readAiWebSearch(session), isFalse);
    expect(askAiAllowed(session, 'launcher.hide'), isFalse);
    expect(
      () => writeAiChoice(session, 'codex'),
      throwsA(isA<FileSystemException>()),
    );
    expect(getSettings().lengthSync(), 65537);
  });

  test(
    'linked settings are unreadable and restrictive, and the writer refuses them',
    () {
      final target = File('${home.path}/settings-target')
        ..writeAsStringSync(
          jsonEncode({
            'helper': 'claude',
            'web_search': true,
            'ask_ai': {'level': 'review'},
          }),
        );
      final original = target.readAsStringSync();
      getSettings().parent.createSync(recursive: true);
      final link = Link(getSettings().path)..createSync(target.path);
      for (final dangling in [false, true]) {
        if (dangling) target.deleteSync();
        expect(readSharedObject(session), isNull);
        expect(sharedFileBroken(session), isTrue);
        expect(readAskAiRules(session).broken, isTrue);
        expect(askAiAllowed(session, 'launcher.hide'), isFalse);
        expect(readAiChoice(session, legacy: 'codex'), 'auto');
        expect(readAiWebSearch(session), isFalse);
        expect(
          () => writeAiChoice(session, 'codex'),
          throwsA(isA<FileSystemException>()),
        );
        expect(link.targetSync(), target.path);
        if (!dangling) expect(target.readAsStringSync(), original);
      }
    },
  );

  test('log append removes partial tails and preserves complete records', () {
    final file = File(askAiLogFile(session));
    file.parent.createSync(recursive: true);
    final complete =
        '${jsonEncode({'time': 'old', 'app': 'launcher', 'action': 'launcher.hide', 'op': 'old'})}\n';
    for (final prefix in ['', complete]) {
      for (final tail in [
        '',
        '{"time":',
        'x' * (askAiLogBytes + 1),
        '\u00e4',
      ]) {
        file.writeAsStringSync('$prefix$tail');
        // Include invalid UTF-8 left by an interrupted write.
        if (tail == '\u00e4')
          file.writeAsBytesSync([0xc3], mode: FileMode.append);
        appendAskAiLog(
          session,
          op: 'new',
          app: 'launcher',
          action: 'launcher.hide',
          target: 'test',
          result: 'done',
        );
        final raw = file.readAsStringSync();
        expect(raw.startsWith(prefix), isTrue);
        final records = raw
            .trim()
            .split('\n')
            .map((line) => jsonDecode(line) as Map)
            .toList();
        expect(records.map((record) => record['op']), [
          if (prefix.isNotEmpty) 'old',
          'new',
        ]);
        expect(readAskAiLog(session).first['op'], 'new');
      }
    }
  });

  test(
    'core proposal binding, re-read on execution, blocked log, manual remains allowed',
    () async {
      final step = await propose();
      expect(step.proposal, matches(RegExp('^[0-9a-f]{48}\$')));
      final other = await propose();
      expect(other.proposal, isNot(step.proposal));
      final good = {'key': step.key, 'proposal': step.proposal, 'hidden': true};
      for (final params in [
        {...good, 'proposal': 'unknown'},
        {...good, 'key': 'another-target'},
      ]) {
        expect(
          (await call('apps.hide', params))['error']['code'],
          'ask_ai_blocked',
        );
      }
      expect(
        (await call('apps.uninstall', good))['error']['code'],
        'ask_ai_blocked',
      );
      rules({
        'actions': {'launcher.hide': false},
      });
      final blocked = await call('apps.hide', good);
      expect(blocked['error'], {
        'code': 'ask_ai_blocked',
        'message': 'Switched off in Maprisma Settings › AI',
      });
      final log = readAskAiLog(session);
      expect(log, hasLength(4));
      expect(
        log.every(
          (line) => line['result'] == 'blocked' && line['app'] == 'launcher',
        ),
        isTrue,
      );
      expect(log.first['op'], step.proposal);
      expect(
        (await call('apps.hide', {'key': step.key, 'hidden': true}))['error'],
        isNull,
      );
      expect(readAskAiLog(session), hasLength(4));
      rules({});
      expect((await call('apps.hide', good))['error'], isNull);
      expect(readAskAiLog(session).first['result'], 'done');
    },
  );

  test(
    'local installs: source/target binding, cached review revocation, Downloads scope',
    () async {
      core.dispose();
      core = CoreService(
        session: session,
        githubReleases: GithubReleases(fetch: (_) async => {'items': []}),
      );
      final downloaded = File('${home.path}/Downloads/Sample.AppImage')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('local test AppImage');
      executable(p.join(home.path, 'bin/claude'), r'''#!/bin/sh
prompt=$(/bin/cat)
case "$prompt" in
  *'Packages found'*) printf '%s\n' '{"summary":"Local","picks":[{"manager":"local","package":"Sample.AppImage","reason":"Downloaded"}],"installed":[]}' ;;
  *) printf '%s\n' '{"action":"search","queries":["Sample"],"installed":[]}' ;;
esac
''');
      final answer = await call('ask.run', {
        'helper': 'claude',
        'request': 'Sample',
      });
      expect(answer['error'], isNull, reason: '$answer');
      final pick = Map<String, dynamic>.from(
        (answer['result']['picks'] as List).single,
      );
      final params = {
        'manager': 'local',
        'package': 'Sample.AppImage',
        'proposal': pick['proposal'],
      };
      expect((await call('packages.install_plan', params))['error'], isNull);
      for (final changed in [
        {...params, 'manager': 'github'},
        {...params, 'package': 'Other.AppImage'},
      ]) {
        expect(
          (await call('packages.install', changed))['error']['code'],
          'ask_ai_blocked',
        );
      }
      rules({
        'folders': {'downloads': false},
      });
      expect(
        (await call('packages.install', params))['error']['code'],
        'ask_ai_blocked',
      );
      expect(
        File('${home.path}/Applications/Sample.AppImage').existsSync(),
        isFalse,
      );
      expect(readAskAiLog(session).first['result'], 'blocked');
      expect(readAskAiLog(session).first['op'], pick['proposal']);
      // Ask gets no local files even through the shared search; manual search still does.
      final denied = await call('ask.run', {
        'helper': 'claude',
        'request': 'Sample',
      });
      expect(denied['result']['picks'], isEmpty);
      final manual = await call('packages.search', {'query': 'Sample'});
      expect(
        (manual['result']['results'] as List).any(
          (f) => f['manager'] == 'local',
        ),
        isTrue,
      );
      expect(downloaded.existsSync(), isTrue);
      // A manual execution of the already-reviewed file is unrestricted.
      expect(
        (await call('packages.install', {
          'manager': 'local',
          'package': 'Sample.AppImage',
        }))['result']['installed'],
        isTrue,
      );
    },
  );

  test(
    'uninstall rechecks rules after asynchronous package ownership preparation',
    () async {
      // A system-owned entry forces the async manager lookup.
      final entry = File('${home.path}/data/applications/writer.desktop');
      final system = File('${home.path}/system/applications/writer.desktop')
        ..parent.createSync(recursive: true);
      entry.renameSync(system.path);
      final step = await propose(action: 'remove');
      rules({});
      executable('${home.path}/bin/pacman', r'''#!/bin/sh
case "$1" in
  -Qqo) printf '%s' '{"ask_ai":{"actions":{"launcher.remove":false}}}' > "$HOME/config/maprisma-ai/settings.json"; echo writer ;;
  -Qi) echo 'Required By : None' ;;
esac
''');
      final result = await call('apps.uninstall', {
        'key': step.key,
        'proposal': step.proposal,
      });
      expect(result['error']['code'], 'ask_ai_blocked', reason: '$result');
      expect(system.existsSync(), isTrue);
      expect(readAskAiLog(session).single['result'], 'blocked');
    },
  );

  test(
    'direct execution records done and failed with the same proposal op',
    () async {
      final step = await propose(action: 'remove');
      final params = {'key': step.key, 'proposal': step.proposal};
      expect((await call('apps.uninstall', params))['result']['done'], isTrue);
      expect((await call('apps.uninstall', params))['error'], isNotNull);
      final log = readAskAiLog(session);
      expect(log.map((e) => e['result']), ['failed', 'done']);
      expect(log.every((e) => e['op'] == step.proposal), isTrue);
    },
  );

  test(
    'non-regular locks and linked log directories are refused without hanging',
    () {
      final lock = File(askAiLogLock(session));
      lock.parent.createSync(recursive: true);
      expect(Process.runSync('/usr/bin/mkfifo', [lock.path]).exitCode, 0);
      appendAskAiLog(
        session,
        op: 'fifo',
        app: 'launcher',
        action: 'launcher.hide',
        target: 'test',
        result: 'done',
      );
      expect(File(askAiLogFile(session)).existsSync(), isFalse);
      lock.deleteSync();
      lock.parent.deleteSync();
      final other = Directory('${home.path}/other')..createSync();
      Link(lock.parent.path).createSync(other.path);
      appendAskAiLog(
        session,
        op: 'link',
        app: 'launcher',
        action: 'launcher.hide',
        target: 'test',
        result: 'done',
      );
      expect(other.listSync(), isEmpty);
    },
  );

  test(
    'every execution boundary rejects unknown proposals before touching a target',
    () async {
      for (final method in [
        'packages.install',
        'apps.uninstall',
        'apps.hide',
        'updates.flatpak',
        'updates.appimage',
        'updates.appimage_restore',
        'updates.system',
        'shortcuts.set',
        'shortcuts.remove',
        'shortcuts.disable',
        'shortcuts.restore',
      ]) {
        expect(
          (await call(method, {
            'proposal': 'unknown',
            'key': 'missing',
            'package': 'sample',
            'manager': 'local',
          }))['error']['code'],
          'ask_ai_blocked',
          reason: method,
        );
      }
      for (final action in [
        'install',
        'uninstall',
        'uninstall_all',
        'system',
      ]) {
        expect(
          (await call('term.start', {
            'proposal': 'unknown',
            'action': action,
            'key': 'missing',
            'keys': ['a', 'b'],
            'package': 'sample',
            'manager': 'local',
          }))['error']['code'],
          'ask_ai_blocked',
          reason: action,
        );
      }
    },
  );

  test(
    'two processes share flock locks, preserve unrelated keys, and append complete records',
    () async {
      rules({
        'actions': {'launcher.remove': false},
      });
      final script = p.absolute('test/fixtures/ask_ai_writer.dart');
      final processes = await Future.wait([
        for (final id in ['a', 'b'])
          Process.start(
            Platform.resolvedExecutable,
            [
              '--packages=${p.absolute('.dart_tool/package_config.json')}',
              script,
              home.path,
              id,
            ],
            environment: {'HOME': home.path},
            includeParentEnvironment: false,
          ),
      ]);
      final results = await Future.wait([
        for (final process in processes)
          () async {
            final stderr = process.stderr.transform(utf8.decoder).join();
            process.stdout.drain<void>().ignore();
            expect(await process.exitCode, 0, reason: await stderr);
          }(),
      ]);
      expect(results, hasLength(2));
      expect(readAskAiRules(session).actions['launcher.remove'], isFalse);
      final contents = getSettings().readAsStringSync();
      expect(jsonDecode(contents)['peer'], 79);
      final lines = File(
        askAiLogFile(session),
      ).readAsLinesSync().map((s) => jsonDecode(s) as Map).toList();
      expect(lines, hasLength(160));
      expect(lines.map((e) => e['op']).toSet(), hasLength(160));
      for (final path in [
        sharedAiFile(session),
        '${aiSettingsDir(session)}/settings.lock',
        askAiLogFile(session),
        askAiLogLock(session),
      ]) {
        expect(FileStat.statSync(path).mode & 0x1ff, 0x180);
      }
    },
  );

  test('log rotation, malformed records and symlinks are safe', () {
    for (var i = 0; i < 1002; i++) {
      appendAskAiLog(
        session,
        op: '$i',
        app: 'launcher',
        action: 'launcher.hide',
        target: 'x' * 250,
        result: 'done',
      );
    }
    final log = readAskAiLog(session, limit: 1100);
    expect(log, hasLength(501));
    expect(log.first['op'], '1001');
    expect((log.first['target'] as String).length, 200);
    File(askAiLogFile(session)).writeAsStringSync(
      'bad\n{"app":"launcher"}\n{"time":',
      mode: FileMode.append,
    );
    expect(readAskAiLog(session, limit: 1100), hasLength(501));
    File(askAiLogFile(session)).deleteSync();
    final victim = File('${home.path}/victim')..writeAsStringSync('keep');
    Link(askAiLogFile(session)).createSync(victim.path);
    appendAskAiLog(
      session,
      op: 'bad',
      app: 'launcher',
      action: 'launcher.hide',
      target: 'x',
      result: 'done',
    );
    expect(victim.readAsStringSync(), 'keep');
  });
}
