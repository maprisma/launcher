import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:maprisma_launcher_core/src/github_releases.dart';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('screenshot request preserves GitHub source and repository URLs', () {
    expect(githubQuery('install craft-launcher from github'), 'craft-launcher');
    expect(githubQuery('install https://github.com/storytold/craft-launcher'), 'storytold/craft-launcher');
    expect(githubQuery('install gimp'), isNull);
    expect(githubQuery('https://github.com.evil.test/a/b'), isNull);
  });
  test('discovery only offers published compatible checksummed release assets', () async {
    final calls = <String>[];
    Map<String, dynamic> asset(String file, {String? digest, String? url}) => {
      'name': file, 'digest': digest ?? 'sha256:${'a' * 64}',
      'browser_download_url': url ?? 'https://github.com/storytold/craft-launcher/releases/download/v1/$file',
    };
    var assets = [asset('craft-arm64.AppImage'), asset('craft-x86_64.AppImage')];
    final github = GithubReleases(fetch: (path) async {
      calls.add(path);
      if (path.startsWith('/search/')) return {'items': [{'full_name': 'storytold/craft-launcher'}]};
      return {'tag_name': 'v1', 'assets': assets};
    });
    final found = await github.search('craft-launcher', architecture: 'x64');
    expect(found.single['package'], 'storytold/craft-launcher');
    expect(found.single['asset'], 'craft-x86_64.AppImage');
    expect(calls.first, contains('craft-launcher'));
    assets = [asset('craft-x64.AppImage', digest: ''), asset('craft-x64.AppImage', url: 'https://evil.test/app')];
    expect(await github.search('craft-launcher', architecture: 'x64'), isEmpty);
    expect(await github.search('craft-launcher', architecture: 'unsupported'), isEmpty);
  });
  test('core preserves GitHub source through preview and refuses unsearched installs', () async {
    final temp = Directory.systemTemp.createTempSync('github-core-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final core = CoreService(environment: {'HOME': temp.path, 'PATH': '/usr/bin:/bin'},
      githubReleases: GithubReleases(fetch: (path) async => path.startsWith('/search/')
        ? {'items': [{'full_name': 'storytold/craft-launcher'}]}
        : {'assets': [{'name': 'craft-x86_64.AppImage', 'digest': 'sha256:${'a' * 64}',
            'browser_download_url': 'https://github.com/storytold/craft-launcher/releases/download/v1/craft-x86_64.AppImage'}]}));
    Future<Map> call(String method, Map<String, dynamic> params) async =>
      jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params}))) as Map;
    final answer = await call('ask.run', {'request': 'install craft-launcher from github'});
    final result = answer['result'] as Map;
    expect(result['source'], 'github');
    expect((result['picks'] as List).single['package'], 'storytold/craft-launcher');
    final preview = await call('packages.install_plan', {'manager': 'github', 'package': 'storytold/craft-launcher'});
    expect(preview['result']['github'], true);
    expect(preview['result']['command'], contains('sha256'));
    final refused = await call('packages.install_plan', {'manager': 'github', 'package': 'other/repo'});
    expect(refused['error'], isNotNull);
  });
  test('verified download is installed, mismatches and overwrites are refused', () async {
    final temp = Directory.systemTemp.createTempSync('github-install-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bin = Directory(p.join(temp.path, 'bin'))..createSync();
    final curl = File(p.join(bin.path, 'curl'));
    curl.writeAsStringSync('#!/bin/sh\nwhile [ "\$#" -gt 0 ]; do\nif [ "\$1" = --output ]; then shift; printf payload > "\$1"; exit; fi\nshift\ndone\nexit 1\n');
    await Process.run('chmod', ['+x', curl.path]);
    final session = Session(home: p.join(temp.path, 'home with space'), environment: {'PATH': '${bin.path}:/usr/bin:/bin'});
    final found = {'package': 'storytold/craft-launcher', 'asset': 'craft-x64.AppImage',
      'url': 'https://github.com/storytold/craft-launcher/releases/download/v1/craft-x64.AppImage',
      'sha256': sha256.convert('payload'.codeUnits).toString()};
    Future<ProcessResult> install() async {
      final argv = githubInstall(session, found, [])!;
      return Process.run(argv.first, argv.sublist(1), environment: session.environment);
    }
    expect((await install()).exitCode, 0);
    final destination = File(p.join(session.home, 'Applications', 'storytold-craft-launcher-craft-x64.AppImage'));
    expect(destination.readAsStringSync(), 'payload');
    expect((await install()).exitCode, isNot(0));
    destination.deleteSync();
    found['sha256'] = 'b' * 64;
    expect((await install()).exitCode, isNot(0));
    expect(destination.existsSync(), isFalse);
    expect(Directory(p.dirname(destination.path)).listSync(), isEmpty);
  });
}
