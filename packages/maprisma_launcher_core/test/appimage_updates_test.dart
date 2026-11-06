import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/core.dart';
import 'package:path/path.dart' as p;

import 'package:maprisma_launcher_core/src/appimage_updates.dart';
import 'package:maprisma_launcher_core/src/facts.dart';
import 'package:test/test.dart';

void main() {
  final source = parseAppImageUpdateInfo(
    "String dump of section '.upd_info':\n"
    '  [     0]  gh-releases-zsync|example|fooeditor|latest|FooEditor-*-linux-x86_64.AppImage.zsync\n',
  )!;

  test(
    'reads a publisher and asset pattern from standard AppImage metadata',
    () {
      expect(source.owner, 'example');
      expect(source.repo, 'fooeditor');
      expect(source.channel, 'latest');
      expect(
        parseAppImageUpdateInfo('No strings found in this section.'),
        isNull,
      );
      expect(
        parseAppImageUpdateInfo(
          'gh-releases-zsync|../bad|repo|latest|app-*.AppImage.zsync',
        ),
        isNull,
      );
    },
  );

  test('accepts a newer matching asset with GitHub SHA-256', () {
    const oldFile = 'FooEditor-1.9.0-linux-x86_64.AppImage';
    const filename = 'FooEditor-1.10.0-linux-x86_64.AppImage';
    const url =
        'https://github.com/example/fooeditor/releases/download/v1.10.0/$filename';
    final release = {
      'tag_name': 'v1.10.0',
      'assets': [
        {
          'name': filename,
          'browser_download_url': url,
          'digest': 'sha256:${'a' * 64}',
        },
      ],
    };
    expect(appImageRelease(release, source, oldFile)?['version'], '1.10.0');
    expect(appImageRelease(release, source, filename), isNull);
    expect(
      appImageRelease(
        {
          ...release,
          'assets': [
            {
              'name': 'FooEditor-1.10.0-linux-aarch64.AppImage',
              'browser_download_url': url,
              'digest': 'sha256:${'a' * 64}',
            },
          ],
        },
        source,
        oldFile,
      ),
      isNull,
    );
    expect(
      appImageRelease(
        {
          ...release,
          'assets': [
            {
              'name': filename,
              'browser_download_url': 'https://example.com/file',
              'digest': 'sha256:${'a' * 64}',
            },
          ],
        },
        source,
        oldFile,
      ),
      isNull,
    );
    expect(
      appImageRelease(
        {
          ...release,
          'assets': [
            {
              'name': filename,
              'browser_download_url': url,
              'digest': 'sha256:bad',
            },
          ],
        },
        source,
        oldFile,
      ),
      isNull,
    );
  });

  test('compares generic AppImage versions and names', () {
    expect(
      newerAppImage('FooEditor-1.9.0.AppImage', 'FooEditor-1.10.0.AppImage'),
      isTrue,
    );
    expect(
      newerAppImage('FooEditor-1.10.0.AppImage', 'FooEditor-1.9.0.AppImage'),
      isFalse,
    );
    expect(
      newerAppImage('FooEditor-1.9.0.AppImage', 'Other-1.10.0.AppImage'),
      isFalse,
    );
    expect(appImageVersion('Maprisma-0.14.1-x86_64.AppImage'), '0.14.1');
  });

  test('fixed asset names use the release tag and installed version record', () {
    final fixed = parseAppImageUpdateInfo(
      'gh-releases-zsync|example|fooeditor|latest|FooEditor-x86_64.AppImage.zsync',
    )!;
    final release = {
      'tag_name': 'v2.1.0',
      'assets': [{
        'name': 'FooEditor-x86_64.AppImage',
        'browser_download_url': 'https://github.com/example/fooeditor/releases/download/v2.1.0/FooEditor-x86_64.AppImage',
        'digest': 'sha256:${'a' * 64}',
      }],
    };
    expect(appImageRelease(release, fixed, 'FooEditor-x86_64.AppImage')?['version'], '2.1.0');
    expect(appImageRelease(release, fixed, 'FooEditor-x86_64.AppImage', installedVersion: '2.1.0'), isNull);
  });

  test('versionless moving build is offered once per checksum', () async {
    final home = Directory.current.createTempSync('.test-appimage-continuous-');
    addTearDown(() => home.deleteSync(recursive: true));
    final old = p.join(home.path, 'App-1.2-x86_64.AppImage');
    File(old).writeAsBytesSync([1, 2, 3]);
    final bytes = List<int>.filled(1024 * 1024, 7);
    final sha = sha256.convert(bytes).toString();
    final source = parseAppImageUpdateInfo(
      'gh-releases-zsync|example|app|continuous|App-*.AppImage.zsync',
    )!;
    const filename = 'App-x86_64.AppImage';
    const tag = 'continuous';
    const url = 'https://github.com/example/app/releases/download/$tag/$filename';
    final json = {
      'tag_name': tag,
      'assets': [{'name': filename, 'browser_download_url': url, 'digest': 'sha256:$sha'}],
    };
    final originalSha = sha256.convert([1, 2, 3]).toString();
    expect(appImageRelease(json, source, p.basename(old)), isNull);
    final release = appImageRelease(json, source, p.basename(old), installedSha256: originalSha)!;
    expect(release['version'], '');
    final updater = AppImageUpdates(Session(environment: {'HOME': home.path}),
      sourceLookup: (_) async => source,
      releaseLookup: (_) async => json,
      download: (_) async => (bytes: Stream.value(bytes), length: bytes.length));
    final app = {'argv': [old], 'desktop_path': ''};
    expect((await updater.check({'app': app}))['updates'], contains('app'));
    await updater.install(app, {...release, 'path': old});
    final record = updater.installedRecord(old)!;
    expect(record.version, isNull);
    expect(record.tag, tag);
    expect(record.sha256, sha);
    expect(appImageRelease(json, source, p.basename(old), installedVersion: '',
      installedSha256: sha), isNull);
    expect((await updater.check({'app': app}))['updates'], isEmpty);
    final changed = {
      ...json,
      'assets': [{'name': filename, 'browser_download_url': url, 'digest': 'sha256:${'a' * 64}'}],
    };
    expect(appImageRelease(changed, source, p.basename(old), installedVersion: '',
      installedSha256: sha), isNotNull);
  });

  test('an AppImage without update metadata reports an unknown status', () async {
    final home = Directory.current.createTempSync('.test-appimage-unknown-');
    addTearDown(() => home.deleteSync(recursive: true));
    final file = File(p.join(home.path, 'FooEditor-1.0.AppImage'))..writeAsBytesSync([1]);
    final check = AppImageUpdates(Session(environment: {'HOME': home.path}),
      sourceLookup: (_) async => null);
    final result = await check.check({'foo': {'argv': [file.path], 'desktop_path': ''}});
    expect((result['updates'] as Map), isEmpty);
    expect((result['unknown'] as Map)['foo'], 'No embedded update source');
  });

  test('update destination rejects shared folders and dangling links', () {
    final root = Directory.current.createTempSync('.test-appimage-update-');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(privateUpdateDirectory(root.path), isTrue);
    final link = Link('${root.path}/new.AppImage')
      ..createSync('${root.path}/missing');
    expect(absentWithoutFollowingLinks(link.path), isFalse);
    Process.runSync('/usr/bin/chmod', ['777', root.path]);
    expect(privateUpdateDirectory(root.path), isFalse);
  });

  test('Flatpak facts retain the installed version for cards', () {
    final facts = parseFlatpakFacts(
      'org.example.Editor\t2.3.1\t42.0 MB\tAn editor\n',
    );
    expect(facts['org.example.Editor'], {
      'version': '2.3.1',
      'size_text': '42.0 MB',
      'description': 'An editor',
    });
  });

  test(
    'verified install keeps the launcher path and can restore the old binary',
    () async {
      final home = Directory.current.createTempSync('.test-appimage-install-');
      addTearDown(() => home.deleteSync(recursive: true));
      final dir = Directory(p.join(home.path, 'Applications'))..createSync();
      final old = p.join(dir.path, 'FooEditor-1.9.0.AppImage');
      File(old).writeAsBytesSync([1, 2, 3]);
      final bytes = List<int>.filled(1024 * 1024, 7);
      final update = AppImageUpdates(
        Session(environment: {'HOME': home.path}),
        sourceLookup: (_) async => source,
        download: (_) async =>
            (bytes: Stream.value(bytes), length: bytes.length),
      );
      final app = {
        'argv': [old],
        'desktop_path': '',
        'desktop_id': 'foo',
      };
      final filename = 'FooEditor-1.10.0-linux-x86_64.AppImage';
      final release = {
        'path': old,
        'filename': filename,
        'tag': 'v1.10.0',
        'url':
            'https://github.com/example/fooeditor/releases/download/v1.10.0/$filename',
        'sha256': sha256.convert(bytes).toString(),
        'owner': 'example',
        'repo': 'fooeditor',
        'channel': 'latest',
        'pattern': source.pattern,
        'version': '1.10.0',
      };
      await update.install(app, release);
      expect(File(old).readAsBytesSync(), bytes);
      expect(File('$old.bak').readAsBytesSync(), [1, 2, 3]);
      expect(update.installedVersion(old), '1.10.0');
      await update.restore(app);
      expect(File(old).readAsBytesSync(), [1, 2, 3]);
      expect(File('$old.bak').readAsBytesSync(), bytes);
      expect(update.installedVersion(old), isNull);
      await update.restore(app);
      expect(File(old).readAsBytesSync(), bytes);
      expect(update.installedVersion(old), '1.10.0');
      final newer = List<int>.filled(1024 * 1024, 8);
      final update2 = AppImageUpdates(Session(environment: {'HOME': home.path}),
        sourceLookup: (_) async => source,
        download: (_) async => (bytes: Stream.value(newer), length: newer.length));
      final newerFilename = 'FooEditor-1.11.0-linux-x86_64.AppImage';
      await update2.install(app, {
        ...release,
        'filename': newerFilename,
        'tag': 'v1.11.0',
        'url': 'https://github.com/example/fooeditor/releases/download/v1.11.0/$newerFilename',
        'sha256': sha256.convert(newer).toString(),
        'version': '1.11.0',
      });
      expect(File(old).readAsBytesSync(), newer);
      expect(File('$old.bak').readAsBytesSync(), bytes);
      await update2.restore(app);
      expect(update2.installedVersion(old), '1.10.0');
    },
  );

  test(
    'bad digest and oversized download leave the original untouched',
    () async {
      final home = Directory.current.createTempSync('.test-appimage-refusal-');
      addTearDown(() => home.deleteSync(recursive: true));
      final dir = Directory(p.join(home.path, 'Applications'))..createSync();
      final old = p.join(dir.path, 'FooEditor-1.9.0.AppImage');
      File(old).writeAsBytesSync([1, 2, 3]);
      final app = {
        'argv': [old],
        'desktop_path': '',
        'desktop_id': 'foo',
      };
      final filename = 'FooEditor-1.10.0-linux-x86_64.AppImage';
      final release = {
        'path': old,
        'filename': filename,
        'tag': 'v1.10.0',
        'url':
            'https://github.com/example/fooeditor/releases/download/v1.10.0/$filename',
        'sha256': 'a' * 64,
        'owner': 'example',
        'repo': 'fooeditor',
        'channel': 'latest',
        'pattern': source.pattern,
        'version': '1.10.0',
      };
      final badDigest = AppImageUpdates(
        Session(environment: {'HOME': home.path}),
        sourceLookup: (_) async => source,
        download: (_) async => (
          bytes: Stream.value(List<int>.filled(1024 * 1024, 7)),
          length: 1024 * 1024,
        ),
      );
      await expectLater(
        badDigest.install(app, release),
        throwsA(isA<FileSystemException>()),
      );
      final tooLarge = AppImageUpdates(
        Session(environment: {'HOME': home.path}),
        sourceLookup: (_) async => source,
        download: (_) async => (
          bytes: const Stream<List<int>>.empty(),
          length: 512 * 1024 * 1024 + 1,
        ),
      );
      await expectLater(
        tooLarge.install(app, release),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(old).readAsBytesSync(), [1, 2, 3]);
      expect(File('$old.bak').existsSync(), isFalse);
    },
  );

  test('a second install of the same path is refused while the first runs', () async {
    final home = Directory.current.createTempSync('.test-appimage-concurrent-');
    addTearDown(() => home.deleteSync(recursive: true));
    final dir = Directory(p.join(home.path, 'Applications'))..createSync();
    final old = p.join(dir.path, 'FooEditor-1.9.0.AppImage');
    File(old).writeAsBytesSync([1]);
    final bytes = List<int>.filled(1024 * 1024, 9);
    final gate = Completer<void>();
    final update = AppImageUpdates(Session(environment: {'HOME': home.path}),
      sourceLookup: (_) async => source,
      download: (_) async { await gate.future; return (bytes: Stream.value(bytes), length: bytes.length); });
    final app = {'argv': [old], 'desktop_path': '', 'desktop_id': 'foo'};
    final filename = 'FooEditor-1.10.0-linux-x86_64.AppImage';
    final release = {
      'path': old, 'filename': filename, 'tag': 'v1.10.0',
      'url': 'https://github.com/example/fooeditor/releases/download/v1.10.0/$filename',
      'sha256': sha256.convert(bytes).toString(), 'owner': 'example',
      'repo': 'fooeditor', 'channel': 'latest', 'pattern': source.pattern,
      'version': '1.10.0',
    };
    final first = update.install(app, release);
    await expectLater(update.install(app, release), throwsA(isA<FileSystemException>()));
    gate.complete();
    await first;
    expect(File(old).readAsBytesSync(), bytes);
  });

  test('placement failure restores the original without leaving a backup', () async {
    final home = Directory.current.createTempSync('.test-appimage-rollback-');
    addTearDown(() => home.deleteSync(recursive: true));
    final old = p.join(home.path, 'FooEditor-1.9.0.AppImage');
    File(old).writeAsBytesSync([1, 2, 3]);
    final bytes = List<int>.filled(1024 * 1024, 7);
    var placements = 0;
    final update = AppImageUpdates(Session(environment: {'HOME': home.path}),
      sourceLookup: (_) async => source,
      download: (_) async => (bytes: Stream.value(bytes), length: bytes.length),
      place: (from, to) async {
        if (placements++ == 0) return false;
        return (await Process.run('/usr/bin/ln', ['--', from, to])).exitCode == 0;
      });
    final filename = 'FooEditor-1.10.0-linux-x86_64.AppImage';
    final release = {
      'path': old, 'filename': filename, 'tag': 'v1.10.0',
      'url': 'https://github.com/example/fooeditor/releases/download/v1.10.0/$filename',
      'sha256': sha256.convert(bytes).toString(),
      'owner': 'example', 'repo': 'fooeditor', 'channel': 'latest',
      'pattern': source.pattern, 'version': '1.10.0',
    };
    await expectLater(update.install({'argv': [old], 'desktop_path': ''}, release), throwsA(isA<FileSystemException>()));
    expect(File(old).readAsBytesSync(), [1, 2, 3]);
    expect(File('$old.bak').existsSync(), isFalse);
  });

  test('update routes refuse an app without an available release or backup', () async {
    final home = Directory.current.createTempSync('.test-appimage-route-');
    addTearDown(() => home.deleteSync(recursive: true));
    final apps = Directory(p.join(home.path, '.local/share/applications'))..createSync(recursive: true);
    final binary = File(p.join(home.path, 'FooEditor-1.9.0.AppImage'))..writeAsBytesSync([1, 2, 3]);
    Process.runSync('/usr/bin/chmod', ['755', binary.path]);
    final desktop = File(p.join(apps.path, 'foo.desktop'))
      ..writeAsStringSync('[Desktop Entry]\nType=Application\nName=Foo Editor\nExec=${binary.path}\n');
    final core = CoreService(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'});
    addTearDown(core.dispose);
    Future<Map> call(String method, [Map<String, dynamic> params = const {}]) async =>
      jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params}))) as Map;
    final listed = (await call('apps.list'))['result']['apps'] as List;
    final key = listed.firstWhere((app) => app['desktop_path'] == desktop.path)['key'];
    expect((await call('updates.appimage', {'key': key}))['error']['code'], 'no_update');
    expect((await call('updates.appimage_restore', {'key': key}))['error']['code'], 'restore_failed');
  });
}
