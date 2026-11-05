import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/github_releases.dart';
import 'package:maprisma_launcher_core/src/search_terms.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('spacing variants and close corrections are generic and bounded', () {
    expect(searchTerms('pdf craft'), ['pdf craft', 'pdf-craft', 'pdfcraft']);
    expect(searchTerms('craf', suggestions: ['craft', 'Minecraft']), ['craf', 'craft']);
    expect(searchTerms('mapisma', suggestions: ['maprisma']), ['mapisma', 'maprisma']);
    expect(searchTerms('notepd', suggestions: ['notepad']), ['notepd', 'notepad']);
    expect(searchTerms('x; touch /tmp/no'), isEmpty);
    expect(searchTerms('a' * 121), isEmpty);
  });

  test('source placement and polite phrases preserve the whole app name', () {
    for (final topic in ['craf', 'pdf craft', 'mapisma', 'some other editor']) {
      for (final request in [
        'list $topic apps from github',
        'search github for $topic',
        'GitHub: $topic',
        'can you find $topic on GitHub?',
      ]) {
        expect(githubQuery(request), topic, reason: request);
      }
    }
  });

  test('real repositories from spacing alternatives are deduplicated and cached', () async {
    final calls = <String>[];
    final github = GithubReleases(
      fetch: (path) async {
        calls.add(path);
        if (path.startsWith('/search/')) {
          final q = Uri.parse(path).queryParameters['q'];
          return {
            'items': q == 'pdf craft in:name,description'
                ? []
                : [
                    {'full_name': 'example/pdf-craft'},
                  ],
          };
        }
        return {'assets': []};
      },
    );
    final found = await github.search('pdf craft');
    expect(found.map((r) => r['package']), ['example/pdf-craft']);
    expect(calls.any((p) => Uri.parse(p).queryParameters['q'] == 'pdf-craft in:name,description'), true);
    final count = calls.length;
    await github.search('pdf craft');
    expect(calls.length, count);
  });

  test('a checked correction ranks ahead of broad original-query results', () async {
    final github = GithubReleases(
      fetch: (path) async {
        if (path.startsWith('/search/')) {
          final corrected = Uri.parse(path).queryParameters['q'] == 'maprisma in:name,description';
          return {
            'items': corrected
                ? [
                    {'full_name': 'example/maprisma'},
                  ]
                : List.generate(5, (i) => {'full_name': 'example/unrelated-$i'}),
          };
        }
        return {'assets': []};
      },
    );
    final found = await github.search('mapisma', suggestions: ['maprisma']);
    expect(found.first['package'], 'example/maprisma');
    expect(found.length, 5);
  });

  test('package managers try spacing forms and deduplicate real matches', () async {
    final home = Directory.systemTemp.createTempSync('package-patterns-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory(p.join(home.path, 'bin'))..createSync();
    final apt = File(p.join(bin.path, 'apt-get'))..writeAsStringSync('#!/bin/sh\nexit 0\n');
    final cache = File(p.join(bin.path, 'apt-cache'))
      ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$3" >> "\$HOME/queries"
if [ "\$3" = pdf-craft ] || [ "\$3" = pdfcraft ]; then printf 'pdf-craft - PDF tools\\n'; fi
''');
    Process.runSync('/bin/chmod', ['+x', apt.path, cache.path]);
    final found = await Managers(
      Session(environment: {'HOME': home.path, 'PATH': bin.path}),
    ).search('pdf craft', ['apt']);
    expect(found.map((f) => f['package']), ['pdf-craft']);
    expect(File(p.join(home.path, 'queries')).readAsLinesSync(), ['pdf craft', 'pdf-craft', 'pdfcraft']);
  });

  test('manual and Ask AI searches use actual GitHub facts, with checked typo hints', () async {
    final home = Directory.systemTemp.createTempSync('search-patterns-');
    addTearDown(() => home.deleteSync(recursive: true));
    final bin = Directory(p.join(home.path, 'bin'))..createSync();
    final helper = File(p.join(bin.path, 'claude'))
      ..writeAsStringSync('''#!/bin/sh
prompt=\$(/bin/cat)
case "\$prompt" in
  *'Packages found'*) echo '{"picks":[{"manager":"github","package":"example/maprisma"}],"installed":[]}' ;;
  *) echo '{"action":"search","queries":["maprisma"],"installed":[]}' ;;
esac
''');
    Process.runSync('/bin/chmod', ['+x', helper.path]);
    var unavailable = false;
    final paths = <String>[];
    final core = CoreService(
      environment: {'HOME': home.path, 'PATH': bin.path, 'MAPRISMA_LAUNCHER_DESKTOP': 'generic'},
      githubReleases: GithubReleases(
        cacheDuration: Duration.zero,
        fetch: (path) async {
          paths.add(path);
          if (unavailable) throw const GithubLookupFailure(403);
          if (path.startsWith('/search/')) {
            final q = Uri.parse(path).queryParameters['q'];
            return {
              'items': q == 'maprisma in:name,description'
                  ? [
                      {'full_name': 'example/maprisma'},
                    ]
                  : [],
            };
          }
          return {'assets': []};
        },
      ),
    );
    Future<Map> call(String method, Map<String, dynamic> params) async =>
        jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})))
            as Map;
    final manual = await call('packages.search', {'query': 'maprisma'});
    expect(manual['result']['results'].single['package'], 'example/maprisma');
    for (final request in ['find mapisma', 'find mapisma from github']) {
      final asked = await call('ask.run', {'request': request, 'helper': 'claude'});
      expect(asked['result']['picks'].single['package'], 'example/maprisma', reason: '$asked');
    }
    expect(paths.any((p) => Uri.parse(p).queryParameters['q'] == 'mapisma in:name,description'), true);
    unavailable = true;
    final failed = await call('packages.search', {'query': 'something'});
    expect(failed['result']['github_unavailable'], true);
  });
}
