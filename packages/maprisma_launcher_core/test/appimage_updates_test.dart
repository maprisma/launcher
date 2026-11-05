import 'dart:io';

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

  test('update destination rejects shared folders and dangling links', () {
    final root = Directory.systemTemp.createTempSync('appimage-update-');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(privateUpdateDirectory(root.path), isTrue);
    final link = Link('${root.path}/new.AppImage')..createSync('${root.path}/missing');
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
}
