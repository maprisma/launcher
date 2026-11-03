/// Change icon's search against icons.py (sample name lists, no network).
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('index entries, ranking, checks and tint equal icons.py', () async {
    final spec = {
      'indexes': {
        'dashboard': {
          'firefox': {'base': 'svg', 'aliases': ['mozilla firefox']},
          'gimp': {'base': 'png'},
          'visual-studio-code': {'base': 'svg', 'aliases': ['vscode', 'code']},
          'BAD SLUG': {'base': 'svg'},
          'claude-ai': {'base': 'svg', 'aliases': ['anthropic claude']},
        },
        'selfhst': [
          {'Reference': 'firefox-dev', 'Name': 'Firefox Developer', 'SVG': 'Yes', 'Tags': 'browser,web'},
          {'Reference': 'nopng', 'Name': 'None', 'SVG': 'No', 'PNG': 'No'},
          {'Reference': 'gimp', 'Name': 'GIMP', 'PNG': 'Yes'},
        ],
        'simple': [
          {'slug': 'anthropic', 'title': 'Anthropic', 'aliases': {'aka': ['Claude']}},
          {'slug': 'firefoxbrowser', 'title': 'Firefox Browser'},
          {'slug': 'dot.slug', 'title': 'x'},
        ],
      },
      'queries': [
        ['firefox', null],
        ['Claude Code', 'claude'],
        ['code', null],
        ['gimp', null],
        ['zz', null],
        ['fire fox', null],
      ],
      'scores': [
        ['firefox', ['firefox']],
        ['fire', ['firefox']],
        ['dev fire', ['firefox developer']],
        ['ref', ['firefox']],
        ['web tool', ['web']],
        ['', ['x']],
      ],
      'looks': [
        ['\x89PNG\r\n\x1a\nrest', 'png'],
        ['GIF89a', 'png'],
        ['  <svg xmlns="x"/>', 'svg'],
        ['<?xml version="1.0"?><svg/>', 'svg'],
        ['<html>', 'svg'],
      ],
    };
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final process = await Process.start('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'icons']);
    process.stdin.write(jsonEncode(spec));
    await process.stdin.close();
    final expected = jsonDecode(await process.stdout.transform(utf8.decoder).join()) as Map;
    expect(await process.exitCode, 0);

    final entries = <(Candidate, List<String>)>[
      for (final e in (spec['indexes'] as Map).entries) ...indexEntries(e.key as String, e.value),
    ];
    expect([for (final (c, n) in entries) [c.$1, c.$2, c.$3, c.$4, n]], expected['entries']);
    expect([
      for (final [q as String, cmd as String?] in spec['queries'] as List)
        [for (final c in searchIcons(q, cmd, entries)) [c.$1, c.$2, c.$3, c.$4]],
    ], expected['search']);
    expect([for (final [q as String, names as List] in spec['scores'] as List) score(q, names.cast<String>())],
        expected['scores']);
    expect([for (final [d as String, k as String] in spec['looks'] as List) looksLike(latin1.encode(d), k)],
        expected['looks']);
    expect(utf8.decode(tint(utf8.encode('<svg viewBox="0 0 1 1"><path/></svg>'), '#aabbcc')), expected['tint']);
  });
}
