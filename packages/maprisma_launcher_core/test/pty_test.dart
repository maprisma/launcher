/// The app's terminal: a real terminal for the program (tty, size, the
/// controlling terminal sudo needs), input, output, the exit code, a hangup.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:test/test.dart';

Future<String> until(PtySession pty, bool Function(String) done, StringBuffer seen) async {
  for (var i = 0; i < 200 && !done(seen.toString()); i++) {
    seen.write(utf8.decode(pty.take(), allowMalformed: true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return seen.toString();
}

void main() {
  final session = Session(environment: Platform.environment);

  test('a terminal of the given size, the controlling one; input; the exit code', () async {
    final pty = (await PtySession.start(
      't1',
      ['sh', '-c', r'tty; stty size; [ -t 0 ] && echo stdin-tty; ps -o tty= -p $$; printf "name? "; read n; echo "hi $n"; exit 3', 'x'],
      session,
      title: 'Test',
      command: 'test',
      cols: 91,
      rows: 27,
    ))!;
    addTearDown(pty.close);
    final seen = StringBuffer();
    var text = await until(pty, (t) => t.contains('name?'), seen);
    expect(text, contains('/dev/pts/'));
    expect(text, contains('27 91'));
    expect(text, contains('stdin-tty'));
    expect(RegExp(r'pts/\d+').allMatches(text).length, greaterThanOrEqualTo(2)); // ps: it is the controlling terminal
    expect(pty.write(utf8.encode('Uwe\r')), 4);
    text = await until(pty, (t) => t.contains('hi Uwe') && pty.ended, seen);
    expect(text, contains('hi Uwe'));
    expect(pty.exitCode, 3);
  });

  test('a resize reaches the program; close hangs up a running one', () async {
    final pty = (await PtySession.start('t2', ['sh', '-c', 'read _; stty size; sleep 30'], session,
        title: 'Test', command: 'test'))!;
    pty.resize(120, 40);
    pty.write(utf8.encode('\r'));
    final seen = StringBuffer();
    expect(await until(pty, (t) => t.contains('40 120'), seen), contains('40 120'));
    final started = DateTime.now();
    pty.close();
    for (var i = 0; i < 100 && !pty.ended; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(pty.ended, isTrue);
    expect(DateTime.now().difference(started).inSeconds, lessThan(5));
  });

  test('routes: the system update in the app terminal (a fake paru), keys in, exit code out; only known actions', () async {
    final home = Directory.systemTemp.createTempSync('am-term-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory('${home.path}/bin')..createSync();
    for (final helper in ['paru', 'yay']) {
      File('${bin.path}/$helper').writeAsStringSync(r'''#!/bin/sh
echo "$(basename "$0") $*"; printf "Proceed? "; read a; echo "answer $a"; exit 0
''');
      Process.runSync('chmod', ['755', '${bin.path}/$helper']);
    }
    final core = CoreService(environment: {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'XDG_DATA_HOME': '${home.path}/data',
      'XDG_DATA_DIRS': '${home.path}/none',
      'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
    });
    Future<Map> call(String method, [Map<String, dynamic> params = const {}]) async {
      final reply = jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params}))) as Map;
      if (reply['error'] case final Map e) return {'error': e['code']};
      return reply['result'] as Map;
    }

    expect(await call('term.start', {'action': 'rm -rf'}), {'error': 'bad_params'});
    expect(await call('term.start', {'action': 'install', 'manager': 'pacman', 'package': 'gimp'}), {'error': 'not_found'});
    final started = await call('term.start', {'action': 'system', 'cols': 80, 'rows': 24});
    expect(started['command'], 'paru -Syu');
    final id = started['id'];
    var text = '';
    Future<void> read(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        final r = await call('term.read', {'id': id});
        text += utf8.decode(base64Decode(r['data'] as String));
        if (r['ended'] == true && done()) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    await read(() => text.contains('Proceed?'));
    expect(text, contains('paru -Syu'));
    expect((await call('term.write', {'id': id, 'data': base64Encode(utf8.encode('y\r'))}))['accepted'], 2);
    await read(() => text.contains('answer y'));
    Map last = {};
    for (var i = 0; i < 100 && last['ended'] != true; i++) {
      last = await call('term.read', {'id': id});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(last['code'], 0);
    expect(await call('term.close', {'id': id}), {'closed': true});
    expect(await call('term.read', {'id': id}), {'error': 'not_found'});
  });
}
