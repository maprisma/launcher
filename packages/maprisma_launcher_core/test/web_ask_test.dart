import 'dart:convert';
import 'dart:io';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/github_releases.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'web answers accept only canonical GitHub identities, never commands or downloads',
    () {
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
    },
  );

  test('web answers keep the page a repository was found on (host only)', () {
    final checked = checkWebAsk({
      'found': [
        {
          'repository': 'https://github.com/storytold/pdfcraft',
          'source': 'https://www.getartcraft.com/apps/pdfcraft',
        },
        {
          'repository': 'https://github.com/storytold/pdfcraft/',
          'source': 'https://other.test',
        },
        {
          'repository': 'https://github.com/a/b',
          'source': 'javascript:alert(1)',
        },
      ],
    });
    expect(checked['found'], [
      {'repository': 'storytold/pdfcraft', 'site': 'getartcraft.com'},
      {'repository': 'a/b'},
    ]);
  });

  test(
    'a named website is recognised; GitHub, ids and other actions are not',
    () {
      expect(namesWebsite('install pdfcraft from getartcraft.com'), true);
      expect(
        namesWebsite('get it from https://getartcraft.com/apps/pdfcraft'),
        true,
      );
      expect(namesWebsite('install org.gnome.Gimp'), false);
      expect(namesWebsite('install https://github.com/a/b'), false);
      expect(namesWebsite('remove pdfcraft from getartcraft.com'), false);
      expect(namesWebsite('install pdfcraft'), false);
    },
  );

  group('web discovery is the shared setting', () {
    late Directory home;
    late List<String> paths;
    late CoreService core;

    // A fake helper: the first call asks for a search; a web call (only web
    // tools enabled) names the official repository and its page.
    void fakeHelper(String name) {
      final bin = Directory(p.join(home.path, 'bin'))
        ..createSync(recursive: true);
      final helper = File(p.join(bin.path, name))
        ..writeAsStringSync(r'''#!/bin/sh
case "$*" in
  *WebSearch,WebFetch*)
    printf '%s\n' "$@" > "$HOME/argv"
    /bin/cat > "$HOME/prompt"
    echo web >> "$HOME/web-calls"
    printf '%s\n' '{"found":[{"repository":"https://github.com/storytold/craft-launcher","source":"https://getartcraft.com/apps/launcher"}],"summary":"Official project"}' ;;
  *)
    /bin/cat > /dev/null
    printf '%s\n' '{"action":"search","queries":["zzqq launcher"],"installed":[]}' ;;
esac
''');
      Process.runSync('/bin/chmod', ['+x', helper.path]);
    }

    void setting(Object? webSearch) {
      final dir = Directory(p.join(home.path, '.config', 'maprisma-ai'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'settings.json')).writeAsStringSync(
        jsonEncode({'helper': 'auto', 'web_search': webSearch}),
      );
    }

    setUp(() {
      home = Directory.systemTemp.createTempSync('web-ask-');
      paths = [];
      core = CoreService(
        environment: {'HOME': home.path, 'PATH': p.join(home.path, 'bin')},
        configDir: p.join(home.path, 'launcher-config'),
        githubReleases: GithubReleases(
          fetch: (path) async {
            paths.add(path);
            if (path.startsWith('/search/')) return {'items': []};
            return path == '/repos/storytold/craft-launcher'
                ? {
                    'full_name': 'storytold/craft-launcher',
                    'name': 'craft-launcher',
                  }
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
    });
    tearDown(() => home.deleteSync(recursive: true));

    Future<Map> call(String method, Map params) async =>
        jsonDecode(
              await core.handleAsync(
                jsonEncode({
                  'id': 1,
                  'protocol': 1,
                  'method': method,
                  'params': params,
                }),
              ),
            )
            as Map;
    Future<Map> ask(String helper, String request) =>
        call('ask.run', {'helper': helper, 'request': request});
    bool webCalled() => File(p.join(home.path, 'web-calls')).existsSync();

    test(
      'off (missing or not true): no web call, the result says it is off',
      () async {
        fakeHelper('claude');
        for (final value in [null, 'true', 1, false]) {
          setting(value);
          final response = await ask('claude', 'zzqq launcher');
          expect(response['error'], isNull, reason: '$response');
          expect(response['result']['picks'], isEmpty);
          expect(response['result']['web_search'], 'off');
        }
        final named = await ask('claude', 'install zzqq from zzqq.example.com');
        expect(named['result']['web'], isNull);
        expect(webCalled(), false);
        expect((await call('ask.helpers', {}))['result']['web_search'], false);
      },
    );

    test(
      'on: nothing found → web; only web tools; the core verifies the release',
      () async {
        fakeHelper('claude');
        setting(true);
        final helpers = (await call('ask.helpers', {}))['result'] as Map;
        expect(helpers['web_search'], true);
        expect(helpers['web_helpers'], ['claude']);
      // Choosing a helper here keeps the Manager's switch.
      await call('ai.helper.set', {'helper': 'claude'});
      expect((await call('ask.helpers', {}))['result']['web_search'], true);
        final response = await ask('claude', 'zzqq launcher');
        expect(response['error'], isNull, reason: '$response');
        final result = response['result'] as Map;
        expect(result['web'], true);
        expect(result['picks'].single['version'], 'v9.9.9');
        expect(result['picks'].single['installable'], true);
        expect(result['web_found'], [
          {'site': 'getartcraft.com', 'repository': 'storytold/craft-launcher'},
        ]);
        expect(
          paths,
          containsAll([
            '/repos/storytold/craft-launcher',
            '/repos/storytold/craft-launcher/releases/latest',
          ]),
        );
        final argv = File(p.join(home.path, 'argv')).readAsLinesSync();
        expect(argv[argv.indexOf('--tools') + 1], 'WebSearch,WebFetch');
        expect(argv[argv.indexOf('--allowedTools') + 1], 'WebSearch,WebFetch');
        expect(argv, contains('--strict-mcp-config'));
        expect(argv, contains('{"disableAllHooks": true}'));
        expect(argv, isNot(contains('--dangerously-skip-permissions')));
        expect(
          Directory(p.join(home.path, 'Applications')).existsSync(),
          false,
        );
        for (final tool in ['curl', 'sha256sum']) {
          Link(p.join(home.path, 'bin', tool)).createSync('/usr/bin/$tool');
        }
        // The install plan is the core's checksum-verified download, never the web's.
        final plan = await call('packages.install_plan', {
          'manager': 'github',
          'package': 'storytold/craft-launcher',
        });
        expect(plan['result']['github'], true);
        expect('${plan['result']['command']}', contains('--check'));
      },
    );

    test('on: a named website goes to the web directly', () async {
      fakeHelper('claude');
      setting(true);
      final response = await ask(
        'claude',
        'install the launcher from getartcraft.com',
      );
      expect(response['result']['web'], true);
      expect(File(p.join(home.path, 'web-calls')).readAsLinesSync(), ['web']);
      expect(paths.where((x) => x.startsWith('/search/')), isEmpty);
    });

    test(
      'on, but a helper without a web-only mode: no web call, a hint',
      () async {
        fakeHelper('agy');
        setting(true);
        final response = await ask('agy', 'zzqq launcher');
        expect(response['error'], isNull, reason: '$response');
        expect(response['result']['picks'], isEmpty);
        expect(response['result']['web_search'], 'unsupported');
        expect(webCalled(), false);
      },
    );
  });
}
