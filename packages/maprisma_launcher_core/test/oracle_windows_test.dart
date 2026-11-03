/// Window matching against the Omarchy plugin, on this machine's apps.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('window classes, matches and Lua strings equal the Omarchy plugin', () async {
    // Synthetic windows of each kind, plus this session's real ones (read only).
    final clients = <Map<String, dynamic>>[
      {'class': 'chromium', 'initialClass': 'chromium', 'title': 'x'},
      {'class': 'chrome-chatgpt.com__-Default', 'title': 'Chat - ChatGPT'},
      {'class': 'chrome-www.ardmediathek.de__-Default', 'title': 'ARD'},
      {'class': 'brave-youtube.com__-Default', 'title': 'Video — YouTube'},
      {'class': 'foot', 'initialClass': 'foot', 'title': 'claude'},
      {'class': 'code', 'title': 'x - Visual Studio Code'},
      {'class': 'org.gnome.Nautilus', 'title': 'Home'},
      {'class': '', 'initialClass': '', 'title': ''},
    ];
    final hyprctl = Process.runSync('hyprctl', ['clients', '-j']);
    if (hyprctl.exitCode == 0) {
      for (final c in jsonDecode(hyprctl.stdout as String) as List) {
        clients.add({'class': c['class'], 'initialClass': c['initialClass'], 'title': c['title']});
      }
    }
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final process = await Process.start('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'windows'],
        environment: {...Platform.environment, 'LANG': 'C'});
    process.stdin.write(jsonEncode(clients));
    await process.stdin.close();
    final err = process.stderr.transform(utf8.decoder).join();
    final expected = jsonDecode(await process.stdout.transform(utf8.decoder).join()) as Map;
    expect(await process.exitCode, 0, reason: await err);
    final apps = await scanApps(Session(environment: {...Platform.environment, 'LANG': 'C'}),
        appIdPrefix: 'io.github.ubruckhaus.Launcher', cacheName: 'gnome-launcher', localized: false);
    expect({for (final a in apps) a['desktop_id']: appWindowClasses(a).toList()..sort()}, expected['classes']);
    expect({for (final a in apps) a['desktop_id']: [for (final c in clients) clientMatchesApp(c, a)]}, expected['matches']);
    expect([for (final t in ['a', 'x"); os.exit("', 'ü\n']) luaString(t)], expected['lua']);
  });
}
