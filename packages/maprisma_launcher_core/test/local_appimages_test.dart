import 'dart:io';
import 'dart:convert';
import 'package:maprisma_launcher_core/src/core.dart';
import 'package:maprisma_launcher_core/src/github_releases.dart';
import 'package:maprisma_launcher_core/src/appimages.dart';
import 'package:test/test.dart';
import 'package:maprisma_launcher_core/src/local_appimages.dart';
import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/posix.dart';
import 'package:maprisma_launcher_core/src/ask_ai.dart';

void main() {
  late Directory home;
  late Session session;
  File download(String name, [List<int> bytes = const [1, 2, 3]]) =>
      File('${home.path}/Downloads/$name')..writeAsBytesSync(bytes);
  setUp(() {
    home = Directory.systemTemp.createTempSync('local-appimages-');
    Directory('${home.path}/Downloads').createSync();
    session = Session(
      environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
    );
  });
  tearDown(() => home.deleteSync(recursive: true));
  test(
    'scan checks names, magic, links, owner, size and installed copies',
    () async {
      download('TaskManagerOG-1.1.1-x86_64.AppImage');
      download('other.appimage');
      download('magic', [127, 69, 76, 70, 0, 0, 0, 0, 65, 73, 2]);
      download('not-an-image');
      download('badmagic', [0, 0, 0, 0, 0, 0, 0, 0, 65, 73, 2]);
      Link(
        '${home.path}/Downloads/link.AppImage',
      ).createSync('${home.path}/Downloads/other.appimage');
      final huge = download('huge.AppImage').openSync(mode: FileMode.write);
      huge.truncateSync(maxDownloadedAppImageBytes + 1);
      huge.closeSync();
      expect((await downloadedAppImages(session)).length, 3);
      expect(
        await downloadedAppImages(session, uid: Posix.instance.uid + 1),
        isEmpty,
      );
      Directory('${home.path}/Applications').createSync();
      File('${home.path}/Applications/other.appimage').writeAsBytesSync([9]);
      // Same filename excluded, and the TaskManager content exists under another filename.
      File(
        '${home.path}/Applications/renamed.AppImage',
      ).writeAsBytesSync([1, 2, 3]);
      expect((await downloadedAppImages(session)).map((f) => f['package']), [
        'magic',
      ]);
    },
  );
  test('XDG config is bounded, regular, never a link', () {
    Directory('${home.path}/.config').createSync();
    final config = File('${home.path}/.config/user-dirs.dirs');
    config.writeAsStringSync('XDG_DOWNLOAD_DIR="\$HOME/Get"\n');
    expect(downloadsDirectory(session), '${home.path}/Get');
    config.writeAsStringSync('x' * 65537);
    expect(downloadsDirectory(session), '${home.path}/Downloads');
    config.deleteSync();
    File('${home.path}/dirs').writeAsStringSync('XDG_DOWNLOAD_DIR="/tmp"');
    Link(config.path).createSync('${home.path}/dirs');
    expect(downloadsDirectory(session), '${home.path}/Downloads');
  });
  test(
    'install copies reviewed bytes, mode 755, no staging remains; identical retry',
    () async {
      final source = download('sample.AppImage');
      final found = (await downloadedAppImages(session)).single;
      final plan = localInstallPlan(session, found);
      expect(plan['sha256'], hasLength(64));
      installLocalAppImage(plan);
      final target = File(plan['destination'] as String);
      expect(target.readAsBytesSync(), source.readAsBytesSync());
      expect(target.statSync().mode & 511, 493);
      expect(Directory('${home.path}/Applications').listSync().length, 1);
      installLocalAppImage(plan);
      expect(source.existsSync(), isTrue);
    },
  );
  test(
    'changed source and different destination are refused without overwrite',
    () async {
      final source = download('sample.AppImage');
      final plan = localInstallPlan(
        session,
        (await downloadedAppImages(session)).single,
      );
      source.writeAsBytesSync([3, 2, 1]);
      expect(
        () => installLocalAppImage(plan),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'reason',
            contains('changed since the review'),
          ),
        ),
      );
      source.writeAsBytesSync([1, 2, 3]);
      Directory('${home.path}/Applications').createSync(recursive: true);
      final target = File(plan['destination'] as String)..writeAsBytesSync([9]);
      expect(
        () => installLocalAppImage(plan),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.readAsBytesSync(), [9]);
      target.deleteSync();
      source.deleteSync();
      final other = File('${home.path}/other')..writeAsBytesSync([1, 2, 3]);
      Link(source.path).createSync(other.path);
      expect(
        () => installLocalAppImage(plan),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test(
    'atomic rename publishes the complete staging file and never overwrites',
    () {
      final staged = File('${home.path}/staged')
        ..writeAsBytesSync(List.filled(100000, 7), flush: true);
      final destination = File('${home.path}/destination');
      expect(Posix.instance.renameNew(staged.path, destination.path), isTrue);
      expect(staged.existsSync(), isFalse);
      expect(destination.readAsBytesSync(), List.filled(100000, 7));
      staged.writeAsBytesSync([9]);
      expect(Posix.instance.renameNew(staged.path, destination.path), isFalse);
      expect(staged.readAsBytesSync(), [9]);
      expect(destination.lengthSync(), 100000);
    },
  );
  test('scan examines at most 50 entries', () async {
    for (var i = 0; i < 55; i++) {
      download('$i.AppImage');
    }
    expect((await downloadedAppImages(session)).length, 50);
  });
  test(
    'core routes require a listed id and review, install offline and rescan',
    () async {
      final source = download('TaskManager.AppImage');
      var networkCalls = 0;
      final core = CoreService(
        session: Session(
          environment: {
            'HOME': home.path,
            'PATH': '/nonexistent',
            'XDG_DATA_DIRS': home.path,
          },
        ),
        githubReleases: GithubReleases(
          fetch: (_) async {
            networkCalls++;
            throw const HttpException('offline');
          },
        ),
      );
      addTearDown(core.dispose);
      Future<Map> call(
        String method, [
        Map<String, dynamic> params = const {},
      ]) async =>
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
      final params = {'manager': 'local', 'package': 'TaskManager.AppImage'};
      expect(
        (await call('packages.install', params))['error']['code'],
        'not_found',
      );
      expect(
        (await call('packages.install_plan', params))['error']['code'],
        'not_found',
      );
      final search = await call('packages.search', {'query': 'TaskManager'});
      expect(search['result']['results'].single['manager'], 'local');
      final review = await call('packages.install_plan', params);
      expect(review['result']['source'], source.path);
      final beforeInstall = networkCalls;
      source.writeAsBytesSync([4, 5, 6]);
      final changed = await call('packages.install', params);
      expect(changed['error']['message'], 'the file changed since the review');
      source.writeAsBytesSync([1, 2, 3]);
      expect(
        (await call('packages.install', params))['result']['installed'],
        isTrue,
      );
      expect(networkCalls, beforeInstall);
      final apps = await scanStandaloneAppImages(session, {});
      expect(apps.single['name'], 'TaskManager');
    },
  );
  test('magic-only file is detected as standalone after install', () async {
    download('portable', [127, 69, 76, 70, 0, 0, 0, 0, 65, 73, 2, 99]);
    installLocalAppImage(
      localInstallPlan(session, (await downloadedAppImages(session)).single),
    );
    expect(
      (await scanStandaloneAppImages(session, {})).single['name'],
      'portable',
    );
  });
  test('Ask AI accepts only exact listed local ids', () {
    final found = [
      {'manager': 'local', 'package': 'sample.AppImage'},
    ];
    final checked = checkPicks(
      {
        'picks': [
          {'manager': 'local', 'package': '/tmp/invented.AppImage'},
          {'manager': 'local', 'package': 'sample.AppImage'},
          {'manager': 'github', 'package': 'sample.AppImage'},
        ],
      },
      found,
      {},
    );
    expect((checked['picks'] as List).length, 1);
    expect(
      askPrompt(
        request: 'install sample',
        installed: [],
        managers: [],
        downloaded: found,
      ),
      contains('sample.AppImage'),
    );
  });
}
