import 'dart:convert';
import 'dart:io';

import 'package:appmanager_core/src/wide_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('wide-window sizes equal launcher.py over a grid of windows', () async {
    final cases = [
      for (final count in [0, 1, 2, 5, 8, 9, 13, 30, 51])
        for (final width in [300, 420, 436, 437, 700, 920, 1524, 2600])
          for (final height in [200, 590, 860, 1400])
            [count, width, height, [48, 72, 128][(count + width) % 3], [50, 70, 100][(count + height) % 3]],
    ];
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final process = await Process.start('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'layout']);
    process.stdin.write(jsonEncode(cases));
    await process.stdin.close();
    final expected = jsonDecode(await process.stdout.transform(utf8.decoder).join()) as List;
    expect(await process.exitCode, 0);
    expect(expected, hasLength(cases.length));
    for (var i = 0; i < cases.length; i++) {
      final [count, width, height, icon, percent] = cases[i];
      final (columns, fitted) = folderFit(count, width, height);
      expect([
        gridColumns(width),
        iconColumns(width, icon),
        folderColumnsAt(width),
        [columns, fitted],
        folderIconsHeight(count, columns, fitted, height),
        folderAppIcon(fitted, percent),
        [folderTileSize(fitted).$1, folderTileSize(fitted).$2],
      ], expected[i], reason: 'case ${cases[i]}');
    }
  });
}
