import 'dart:convert';
import 'dart:io';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:maprisma_launcher_core/src/cosmic_windows.dart';
import 'package:maprisma_launcher_core/src/groups.dart' as groups;
import 'package:test/test.dart';

void main() {
  const youtube = {
    'key': 'yt',
    'desktop_id': 'chrome-agimnkijcaahngcdmfeangaknmldooml-Default',
    'startup_class': 'crx_agimnkijcaahngcdmfeangaknmldooml',
    'exec': '/usr/bin/google-chrome --app-id=agimnkijcaahngcdmfeangaknmldooml',
  };
  test('YouTube matches its desktop id, case insensitively', () {
    expect(
      cosmicWindowMatches({
        'app_id': 'CHROME-agimnkijcaahngcdmfeangaknmldooml-Default',
      }, youtube),
      isTrue,
    );
    expect(cosmicWindowMatches({'app_id': 'unrelated'}, youtube), isFalse);
  });
  test('StartupWMClass and executable basename match', () {
    expect(
      cosmicWindowMatches({
        'app_id': 'CRX_agimnkijcaahngcdmfeangaknmldooml',
      }, youtube),
      isTrue,
    );
    expect(
      cosmicWindowMatches(
        {'app_id': 'EDITOR'},
        {'exec': '/usr/bin/editor --flag'},
      ),
      isTrue,
    );
    expect(cosmicWindowMatches({'app_id': ''}, {'exec': 'bad "'}), isFalse);
  });
  test(
    'terminal command has no claimed terminal window and stays background',
    () {
      final apps = <String, Map>{
        'yt': youtube,
        'cli': {
          'key': 'cli',
          'exec': 'cosmic-term -e claude',
          'startup_class': 'com.system76.CosmicTerm',
        },
      };
      final states = cosmicStates(
        apps,
        [
          {'id': 'stable/1', 'app_id': youtube['desktop_id'], 'active': false},
          {'id': 'stable/2', 'app_id': 'com.system76.CosmicTerm'},
        ],
        {'google-chrome', 'claude', 'cosmic-term'},
        {'cosmic-term': 1},
      );
      expect(states, {'yt': 'active', 'cli': 'background'});
      final running = states.keys.toSet();
      final selected = groups.sections(
        apps.values.toList(),
        groups.defaultPage(),
        isRunning: (app) =>
            inRunningCard(app['key'] as String, running, states),
      );
      expect(selected.first.$2, [youtube]);
      expect(inRunningCard('cli', running, null), isTrue);
      expect(inRunningCard('cli', running, {}), isFalse);
    },
  );
  test(
    'COSMIC routes use bundled helper, allowlisted focus and app-scoped close',
    () async {
      final home = Directory.systemTemp.createTempSync('cosmic-routes-');
      addTearDown(() => home.deleteSync(recursive: true));
      final appsDir = Directory('${home.path}/data/applications')
        ..createSync(recursive: true);
      File('${appsDir.path}/youtube.desktop').writeAsStringSync(
        '[Desktop Entry]\nType=Application\nName=YouTube\nExec=/bin/true\n',
      );
      final helper = File('${home.path}/maprisma-launcher-windows');
      helper.writeAsStringSync(r'''#!/bin/sh
case "$1" in
list) printf '%s\n' '{"available":true,"windows":[{"id":"opaque/yt","app_id":"youtube","title":"YouTube","workspace":2,"active":false},{"id":"other","app_id":"other","title":"Other","workspace":1,"active":true}]}' ;;
activate|close) printf '%s\n' '{"done":true}' ;;
esac
''');
      await Process.run('/bin/chmod', ['+x', helper.path]);
      final core = CoreService(
        executable: '${home.path}/launcher',
        environment: {
          'HOME': home.path,
          'PATH': '/nonexistent',
          'XDG_DATA_HOME': '${home.path}/data',
          'XDG_DATA_DIRS': '${home.path}/none',
          'MAPRISMA_LAUNCHER_DESKTOP': 'cosmic',
          'XDG_CURRENT_DESKTOP': 'COSMIC',
        },
      );
      Future<Map> call(String method, [Map params = const {}]) async {
        final reply =
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
        if (reply['error'] != null) return {'error': reply['error']};
        return reply['result'] as Map;
      }

      final entries = (await call('apps.list'))['apps'] as List;
      final key = (entries.single as Map)['key'];
      final running = await call('apps.running');
      expect((running['states'] as Map)[key], 'active');
      final sections =
          (await call('apps.sections', {
                'view': 'groups',
                'keys': [key],
                'running': true,
              }))['sections']
              as List;
      expect(sections.first['keys'], [key]);
      final windows =
          (await call('apps.windows', {'key': key}))['windows'] as List;
      expect(windows.single, {
        'address': 'opaque/yt',
        'title': 'YouTube',
        'workspace': 2,
      });
      expect(await call('window.focus', {'address': 'opaque/yt'}), {
        'focused': true,
      });
      expect(
        (await call('window.focus', {'address': 'unlisted'}))['error']['code'],
        'not_found',
      );
      expect(await call('apps.close', {'key': key, 'address': 'other'}), {
        'closed': 0,
      });
      expect(await call('apps.close', {'key': key}), {'closed': 1});
      helper.writeAsStringSync('''#!/bin/sh
printf '%s\n' '{"available":true,"windows":[]}'
''');
      expect((await call('apps.running'))['states'], isEmpty);
      final emptySections =
          (await call('apps.sections', {
                'view': 'groups',
                'keys': [key],
                'running': true,
              }))['sections']
              as List;
      expect(emptySections.first['keys'], isEmpty);
      helper.writeAsStringSync('''#!/bin/sh
printf '%s\n' '{"available":false}'
''');
      expect((await call('apps.running')).containsKey('states'), isFalse);
    },
  );
  test('opaque ids are bounded and exclude control characters', () {
    expect(CosmicWindows.validId('stable/opaque:id-1'), isTrue);
    for (final id in ['', 'a\nb', 'x' * 513, null]) {
      expect(CosmicWindows.validId(id), isFalse);
    }
  });
}
