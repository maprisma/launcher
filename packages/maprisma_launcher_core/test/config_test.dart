import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late ConfigStore store;
  setUp(() {
    home = Directory.systemTemp.createTempSync('am-config-');
    store = ConfigStore(Session(environment: {'HOME': home.path}));
  });
  tearDown(() => home.deleteSync(recursive: true));

  void old(String app, String name, Object data) =>
      File(p.join(home.path, '.config', app, name))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(data));

  test('first start copies the newer old app, apps page only, originals stay', () {
    old('gnome-launcher', 'groups.json', {'apps': {'groups': []}});
    sleep(const Duration(milliseconds: 20));
    old('applauncher', 'groups.json', {
      'apps': {'groups': [{'id': 'g1', 'name': 'AI'}]},
      'plugins': {'groups': []},
    });
    old('applauncher', 'hidden.json', ['x']);
    final result = store.importOldConfig();
    expect(result['from'], p.join(home.path, '.config/applauncher'));
    expect(result['copied'], ['groups.json', 'hidden.json']);
    expect(store.readJson('groups.json'), {
      'apps': {'groups': [{'id': 'g1', 'name': 'AI'}]},
    });
    expect(loadHidden(store), {'x'});
    expect(File(p.join(home.path, '.config/applauncher/groups.json')).existsSync(), isTrue);
    // Once there are own files, nothing is copied again.
    expect(store.importOldConfig(), isEmpty);
  });

  test('files are private and written through no symlink', () {
    final target = File(p.join(home.path, 'elsewhere.json'))..writeAsStringSync('{}');
    Directory(store.dir).createSync(recursive: true);
    Link(store.path('settings.json')).createSync(target.path);
    Link(store.path('.hidden.json.$pid.tmp')).createSync(target.path);
    store.writeJson('settings.json', {'a': 1});
    saveHidden(store, {'b'});
    expect(target.readAsStringSync(), '{}');
    expect(FileSystemEntity.isLinkSync(store.path('settings.json')), isFalse);
    expect(File(store.path('settings.json')).statSync().modeString(), 'rw-------');
    expect(File(store.path('hidden.json')).statSync().modeString(), 'rw-------');
  });

  test('settings: defaults, checked values, old icon size', () {
    final settings = Settings(store);
    expect(settings.read()['view'], 'list');
    expect(settings.read()['icon_sizes'], defaultIconSizes);
    store.writeJson('settings.json', {'app_icon_size': 56, 'view': 'bogus', 'shown_layouts': []});
    expect(settings.read()['icon_sizes'], {...defaultIconSizes, 'cards': 56, 'list': 44});
    expect(settings.read()['view'], 'list');
    expect(settings.read()['shown_layouts'], wideLayouts);
    settings.set('view', 'groups');
    settings.set('icon_size', {'view': 'icons', 'size': 96});
    expect(settings.read()['view'], 'groups');
    expect((settings.read()['icon_sizes'] as Map)['icons'], 96);
    expect(() => settings.set('view', 'x'), throwsArgumentError);
    expect(() => settings.set('icon_size', {'view': 'icons', 'size': 97}), throwsArgumentError);
    expect(() => settings.set('nope', 1), throwsArgumentError);
    // Unknown keys of the old app stay in the file.
    expect(settings.raw()['app_icon_size'], 56);
    expect(settings.read()['language'], 'auto');
    settings.set('language', 'de');
    expect(settings.read()['language'], 'de');
    settings.set('language', 'auto');
    expect(settings.raw().containsKey('language'), isFalse);
    expect(() => settings.set('language', 'xx'), throwsArgumentError);
    store.writeJson('settings.json', {...settings.raw(), 'dock_pinned': ['x'], 'size': [900, 700]});
    settings.reset();
    expect(settings.read()['view'], 'list');
    expect(settings.read()['icon_sizes'], defaultIconSizes);
    expect(settings.raw()['dock_pinned'], ['x']);
    expect(settings.read()['size'], [900, 700]);
    expect(settings.read()['screenshot_key'], isTrue);
    expect(settings.read()['screenshot_folder'], isNull);
    settings.set('screenshot_key', false);
    settings.set('screenshot_folder', '/tmp/shots');
    expect(settings.read()['screenshot_key'], isFalse);
    expect(settings.read()['screenshot_folder'], '/tmp/shots');
    expect(() => settings.set('screenshot_folder', 'relative'), throwsArgumentError);
    settings.set('screenshot_folder', null);
    expect(settings.raw().containsKey('screenshot_folder'), isFalse);
  });
}
