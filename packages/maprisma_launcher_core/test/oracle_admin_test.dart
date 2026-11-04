/// Open as administrator: the commands against admin_command, every app here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('admin commands equal admin_command', () async {
    final env = {...Platform.environment, 'LANG': 'C'};
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final r = await Process.run('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'admin'], environment: env);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final expected = jsonDecode(r.stdout as String) as Map;
    final session = Session(environment: env);
    final apps = await scanApps(session, appIdPrefix: 'io.github.ubruckhaus.Launcher', cacheName: 'gnome-launcher', localized: false);
    final admin = Admin(session);
    expect({for (final a in apps) a['desktop_id']: await admin.command(a)}, expected);
    expect(expected.values.where((v) => v != null), isNotEmpty);
  }, skip: Platform.environment['MAPRISMA_LIVE_TESTS'] == '1' ? null : 'requires installed apps');

  test('the opt-in: a private marker naming this login session', () {
    final dir = Directory.systemTemp.createTempSync('am-admin-');
    addTearDown(() => dir.deleteSync(recursive: true));
    Process.runSync('chmod', ['700', dir.path]);
    final sessions = Directory(p.join(dir.path, 'sessions'))..createSync();
    final boot = File(p.join(dir.path, 'boot'))..writeAsStringSync('0123abcd-0123-4567-89ab-0123456789ab\n');
    // The real record is root-owned; here it is ours, so no token: the switch stays off.
    File(p.join(sessions.path, 'c7')).writeAsStringSync('UID=${Posix.instance.uid}\nSTATE=active\nREALTIME=123\n');
    final admin = Admin(Session(environment: {'HOME': dir.path, 'XDG_RUNTIME_DIR': dir.path, 'XDG_SESSION_ID': 'c7'}),
        sessionsDir: sessions.path, bootIdFile: boot.path);
    expect(admin.sessionDir(), dir.path);
    expect(admin.sessionToken(), isNull);
    expect(admin.enabled(), isFalse);
    expect(() => admin.setEnabled(true), throwsA(isA<FileSystemException>()));
    // A runtime folder others can enter is refused.
    Process.runSync('chmod', ['755', dir.path]);
    expect(admin.sessionDir(), isNull);
  });
}
