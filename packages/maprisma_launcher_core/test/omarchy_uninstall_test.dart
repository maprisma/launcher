import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('Omarchy: omarchy-remove-launcher-entry decides; only id and name go to it', () async {
    final home = Directory.systemTemp.createTempSync('am-oma-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory(p.join(home.path, 'bin'))..createSync();
    for (final name in ['omarchy-remove-launcher-entry', 'omarchy-launch-webapp', 'xdg-terminal-exec', 'tool']) {
      File(p.join(bin.path, name))
        ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$0" "\$@" >> "\$HOME/calls"\n')
        ..createSync();
      Process.runSync('chmod', ['+x', p.join(bin.path, name)]);
    }
    final apps = Directory(p.join(home.path, 'data/applications'))..createSync(recursive: true);
    File(p.join(apps.path, 'HEY.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=HEY; rm -rf ~\nExec=omarchy-launch-webapp https://app.hey.com\n',
    );
    File(p.join(apps.path, 'Btop.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=Btop\nExec=xdg-terminal-exec --app-id=x -e btop\n',
    );
    File(p.join(apps.path, 'mine.desktop'))
        .writeAsStringSync('[Desktop Entry]\nType=Application\nName=Mine\nExec=tool\n');
    final core = CoreService(environment: {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'XDG_DATA_HOME': p.join(home.path, 'data'),
      'XDG_DATA_DIRS': p.join(home.path, 'none'),
      'MAPRISMA_LAUNCHER_DESKTOP': 'omarchy',
    });
    Future<Map> call(String method, [Map<String, dynamic> params = const {}]) async =>
        jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})))
            as Map;
    await call('apps.list');
    String key(String file) => p.join(apps.path, file);
    Future<Map> plan(String file) async => (await call('apps.uninstall_plan', {'key': key(file)}))['result'] as Map;
    expect((await plan('HEY.desktop'))['how'], 'webapp');
    expect(await plan('Btop.desktop'), containsPair('how', 'tui'));
    expect((await plan('mine.desktop'))['how'], 'own');
    final done = await call('apps.uninstall', {'key': key('HEY.desktop')});
    expect(done['result'], {'done': true});
    final calls = File(p.join(home.path, 'calls')).readAsLinesSync();
    expect(calls, [p.join(bin.path, 'omarchy-remove-launcher-entry'), 'HEY', 'HEY; rm -rf ~']);
  });
}
