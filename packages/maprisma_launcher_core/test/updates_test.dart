import 'dart:io';

import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/updates.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('checks package and Flatpak updates from their managers', () async {
    final home = Directory.systemTemp.createTempSync('launcher-updates-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory(p.join(home.path, 'bin'))..createSync();
    void command(String name, String body) {
      final file = File(p.join(bin.path, name))..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('/usr/bin/chmod', ['755', file.path]);
    }
    command('pacman', "printf '%s\\n' '/usr/share/applications/browser.desktop is owned by browser 1.0'");
    command('checkupdates', "printf '%s\\n' 'browser 1.0 -> 1.1'");
    command('yay', "printf '%s\\n' 'helper-git 2.0 -> 2.1'");
    command('flatpak', '''
if [ "\$1" = remote-ls ]; then
  printf 'org.example.Paint\\t2.0\\n'
else
  printf 'org.example.Paint\\t1.0\\n'
fi
''');
    final session = Session(environment: {'HOME': home.path, 'PATH': '${bin.path}:/usr/bin:/bin'});
    final result = await UpdateCheck(session).check(['/usr/share/applications/browser.desktop']);
    expect((result['apps'] as Map)['/usr/share/applications/browser.desktop'], ['browser', '1.0', '1.1']);
    expect((result['flatpaks'] as Map)['org.example.Paint'], ['1.0', '2.0']);
    expect((await UpdateCheck(session).packageUpdates())['helper-git'], ('2.0', '2.1'));
  });
}
