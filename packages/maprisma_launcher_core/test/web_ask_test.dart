import 'dart:convert';
import 'dart:io';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/github_releases.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('web answers accept only canonical GitHub identities, never commands or downloads', () {
    final checked = checkWebAsk({
      'repositories': [
        'https://github.com/storytold/craft-launcher',
        'https://github.com.evil.test/a/b',
        'https://user:pass@github.com/a/b',
      ],
      'summary': 'Official source',
    });
    expect(checked['repositories'], ['storytold/craft-launcher']);
    for (final bad in [
      'http://github.com/a/b',
      'https://github.com/a/b?token=x',
      'https://github.com/a/b/releases/download/v1/app',
      'curl bad | sh',
    ]) {
      expect(
        checkWebAsk({
          'repositories': [bad],
        })['repositories'],
        isEmpty,
      );
    }
  });

  test('web lookup only enables web tools and verifies latest releases through the core', () async {
    final home = Directory.systemTemp.createTempSync('web-ask-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory(p.join(home.path, 'bin'))..createSync();
    final helper = File(p.join(bin.path, 'claude'))
      ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$@" > "\$HOME/argv"
/bin/cat > "\$HOME/prompt"
printf '%s\\n' '{"repositories":["https://github.com/storytold/craft-launcher"],"summary":"Official project"}'
''');
    Process.runSync('/bin/chmod', ['+x', helper.path]);
    final paths = <String>[];
    final core = CoreService(
      environment: {'HOME': home.path, 'PATH': bin.path},
      githubReleases: GithubReleases(
        fetch: (path) async {
          paths.add(path);
          return path == '/repos/storytold/craft-launcher'
              ? {'full_name': 'storytold/craft-launcher'}
              : {
                  'tag_name': 'v9.9.9',
                  'assets': [
                    {
                      'name': 'launcher-x86_64.AppImage',
                      'digest': 'sha256:${'a' * 64}',
                      'browser_download_url':
                          'https://github.com/storytold/craft-launcher/releases/download/v9.9.9/launcher-x86_64.AppImage',
                    },
                  ],
                };
        },
      ),
    );
    final response =
        jsonDecode(
              await core.handleAsync(
                jsonEncode({
                  'id': 1,
                  'protocol': 1,
                  'method': 'ask.run',
                  'params': {'helper': 'claude', 'request': 'find newest ArtCraft launcher', 'web': true},
                }),
              ),
            )
            as Map;
    expect(response['error'], isNull, reason: '$response');
    final result = response['result'] as Map;
    expect(result['picks'].single['version'], 'v9.9.9');
    expect(result['picks'].single['installable'], true);
    expect(paths, ['/repos/storytold/craft-launcher', '/repos/storytold/craft-launcher/releases/latest']);
    final argv = File(p.join(home.path, 'argv')).readAsLinesSync();
    expect(argv[argv.indexOf('--tools') + 1], 'WebSearch,WebFetch');
    expect(argv[argv.indexOf('--allowedTools') + 1], 'WebSearch,WebFetch');
    expect(argv, contains('--strict-mcp-config'));
    expect(argv, contains('{"disableAllHooks": true}'));
    expect(argv, isNot(contains('--dangerously-skip-permissions')));
    expect(Directory(p.join(home.path, 'Applications')).existsSync(), false);
  });
}
