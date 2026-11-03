/// The scan against the Python reference on fixture homes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appmanager_core/appmanager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final repo = p.normalize(p.join(Directory.current.path, '../..'));

Future<List> oracle(Map<String, String> env) async {
  final result = await Process.run(
    '/usr/bin/python3',
    ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'scan'],
    environment: env,
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return jsonDecode(result.stdout as String) as List;
}

Future<void> same(Map<String, String> env, int count) async {
  final expected = await oracle(env);
  expect(expected, hasLength(count));
  expect(await dart(env), expected);
}

Future<List> dart(Map<String, String> env) async => jsonDecode(
  jsonEncode(
    await scanApps(
      Session(environment: env),
      appIdPrefix: 'io.github.ubruckhaus.Launcher',
      cacheName: 'gnome-launcher',
      localized: false,
    ),
  ),
) as List;

void writeExec(String path, [String body = '#!/bin/sh\n']) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(body);
  Process.runSync('chmod', ['+x', path]);
}

void entry(String dir, String id, String text) =>
    File(p.join(dir, '$id.desktop'))
      ..createSync(recursive: true)
      ..writeAsStringSync(text);

void main() {
  late Directory home;
  late Map<String, String> env;

  setUp(() {
    home = Directory.systemTemp.createTempSync('am-oracle-');
    final bin = p.join(home.path, 'sysbin');
    env = {
      'HOME': home.path,
      'PATH': '$bin:/usr/bin:/bin',
      'XDG_DATA_HOME': p.join(home.path, 'data'),
      'XDG_DATA_DIRS': p.join(home.path, 'sys'),
      'LANG': 'de_DE.UTF-8',
    };
    writeExec(p.join(bin, 'tool'));
    writeExec(p.join(bin, 'other'));
    writeExec(p.join(bin, 'claude'));
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('desktop entries: shadowing, names, env, PWAs, hostile files', () async {
    final user = p.join(home.path, 'data/applications');
    final sys = p.join(home.path, 'sys/applications');
    entry(user, 'a', '[Desktop Entry]\nType=Application\nName=Alpha\nExec=tool %U\n'
        'Actions=new;priv;\nCategories=Office;;Graphics;\n\n'
        '[Desktop Action new]\nName=New\nName[de]=Neu\nExec=tool --new\n'
        '[Desktop Action priv]\nExec=tool --private %u\n');
    entry(sys, 'a', '[Desktop Entry]\nName=Shadowed\nExec=tool\n');
    entry(sys, 'b', '[Desktop Entry]\nType=Application\nName=alpha \nExec=other\n');
    entry(sys, 'c', '[Desktop Entry]\nType=Application\nName=Env\n'
        'Exec=env FOO=1 -u BAR other --x\nTerminal=true\nX-Flatpak=org.x\n');
    entry(sys, 'd', '[Desktop Entry]\nName=Path env\nExec=env PATH=/nowhere tool\n');
    entry(sys, 'e', '[Desktop Entry]\nName=Missing\nExec=does-not-exist\n');
    entry(sys, 'f', '[Desktop Entry]\nName=Hidden\nExec=tool\nNoDisplay=true\n');
    entry(sys, 'g', '[Desktop Entry]\nName=Web App\nExec=tool --app-id=x\n'
        'NoDisplay=true\nStartupWMClass=crx_abc\nIcon=/x/y.png\n');
    entry(sys, 'h', '[Desktop Entry]\nName=Try\nExec=tool\nTryExec=nope\n');
    entry(sys, 'i', '[Desktop Entry]\nName=Quote\nExec=tool "unclosed\n');
    entry(sys, 'j', 'garbage line\n[Desktop Entry]\nType=Application\nName=Bad keyfile\n'
        'Exec=tool\nActions=x;\n[Desktop Action x]\nName=X\n');
    entry(sys, 'k', '[Desktop Entry]\nType=Link\nName=Link type\nExec=tool\nActions=y\n');
    entry(sys, 'l', '[Desktop Entry]\nName = Spaced\nExec=tool\n');
    File(p.join(sys, 'big.desktop')).writeAsStringSync(
      '[Desktop Entry]\nName=Big\nExec=tool\n#${'x' * (300 * 1024)}\n',
    );
    Process.runSync('mkfifo', [p.join(sys, 'fifo.desktop')]);
    Link(p.join(sys, 'link.desktop')).createSync(p.join(sys, 'missing-target'));
    await same(env, 7);
  });

  test('AppImages: versions, noise words, started by a desktop file', () async {
    final apps = p.join(home.path, 'Applications');
    for (final name in [
      'photocraft-0.14.0-linux-x86_64.AppImage',
      'photocraft-0.9.0-linux-x86_64.AppImage',
      'Foo-3D-1.0.AppImage',
      'Tool-1.0rc1.AppImage',
      'Tool-1.0.AppImage',
      'Tool-1.0rc2.appimage',
      'Bar_v2-x86_64.AppImage',
      'Started-2.0.AppImage',
      'Started-1.0.AppImage',
      'Alpha-9.AppImage',
    ]) {
      writeExec(p.join(apps, name));
    }
    File(p.join(apps, 'NotExec-1.0.AppImage')).writeAsStringSync('');
    final started = p.join(apps, 'Started-1.0.AppImage');
    entry(p.join(home.path, 'data/applications'), 'started',
        '[Desktop Entry]\nName=Started app\nExec=$started\n');
    entry(p.join(home.path, 'sys/applications'), 'alpha',
        '[Desktop Entry]\nName=Alpha\nExec=tool\n');
    // No 7z on this PATH: names come from the file names.
    env['PATH'] = '${p.join(home.path, 'sysbin')}:/bin-none';
    await same(env, 7);
  });

  test('CLI tools: mise wrappers, shims, PATH agents', () async {
    final local = p.join(home.path, '.local');
    writeExec(
      p.join(local, 'bin/codex'),
      '#!/bin/bash\nexec mise x "npm:@openai/codex" -- "codex" "\$@"\n',
    );
    writeExec(
      p.join(local, 'bin/opencode'),
      '#!/bin/bash\nexec mise x "opencode" -- "opencode" "\$@"\n',
    );
    writeExec(
      p.join(local, 'bin/node'),
      '#!/bin/bash\nexec mise x "node" -- "node" "\$@"\n',
    );
    writeExec(
      p.join(local, 'bin/notinstalled'),
      '#!/bin/bash\nexec mise x "ghost" -- "notinstalled" "\$@"\n',
    );
    Directory(p.join(local, 'share/mise/installs/npm-openai-codex')).createSync(recursive: true);
    Directory(p.join(local, 'share/mise/installs/opencode')).createSync(recursive: true);
    Directory(p.join(local, 'share/mise/installs/node')).createSync(recursive: true);
    writeExec(p.join(local, 'share/mise/shims/gemini'));
    entry(p.join(home.path, 'sys/applications'), 'oc',
        '[Desktop Entry]\nName=OC\nExec=foot -e opencode\n');
    writeExec(p.join(home.path, 'sysbin/foot'));
    await same(env, 3);
  });
}
