import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_launcher_core/src/config.dart';
import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/launch.dart';
import 'package:maprisma_launcher_core/src/shortcut_service.dart';
import 'package:maprisma_launcher_core/src/shortcuts.dart';
import 'package:maprisma_launcher_core/src/shortcuts_kde.dart';

base class FakeKGlobalAccel implements KGlobalAccel {
  final registrations = <String, List<String>>{};
  final keys = <String, List<List<int>>>{};
  String id(List<String> a) => '${a[0]}:${a[1]}';
  @override
  Future<List<String>> components() async =>
      registrations.values.map((a) => a[0]).toSet().toList();
  @override
  Future<List<List<String>>> actions(String component) async =>
      registrations.values.where((a) => a[0] == component).toList();
  @override
  Future<List<List<int>>> shortcutKeys(List<String> action) async =>
      keys[id(action)] ?? [];
  @override
  Future<void> setForeignShortcutKeys(
    List<String> action,
    List<List<int>> values,
  ) async {
    keys[id(action)] = values;
  }

  @override
  Future<void> doRegister(List<String> action) async {
    registrations[id(action)] = action;
  }

  @override
  Future<void> unregister(String component, String action) async {
    registrations.remove('$component:$action');
    keys.remove('$component:$action');
  }
}

void main() {
  test('Qt conversion including shifted digits and navigation', () {
    for (final key in [
      ...keyMapKeys,
      'Left',
      'Right',
      'Up',
      'Down',
      'Escape',
      'F35',
      'KP_Enter',
    ]) {
      for (final mods in [
        <String>[],
        ['SUPER', 'SHIFT', 'CTRL', 'ALT'],
      ]) {
        final accel = accelerator(makeCombo(mods, key)!);
        expect(qtToAccelerator(acceleratorToQt(accel)!), accel);
      }
    }
    expect(acceleratorToQt('<Shift>1'), 0x02000031);
    expect(qtToAccelerator(0x02000031), '<Shift>1');
    expect(qtToAccelerator(0x20000041), isNull);
    expect(acceleratorToQt('<Hyper>a'), isNull);
    expect(acceleratorToQt('Unknown'), isNull);
  });
  late Directory home;
  late Session session;
  late FakeKGlobalAccel fake;
  late KdeSettings settings;
  setUp(() {
    home = Directory.systemTemp.createTempSync('maprisma-kde-test-');
    session = Session(
      environment: {
        'HOME': home.path,
        'XDG_DATA_HOME': '${home.path}/data',
        'XDG_DATA_DIRS': '${home.path}/system',
        'XDG_CONFIG_HOME': '${home.path}/config',
      },
    );
    fake = FakeKGlobalAccel();
    settings = KdeSettings(session, globalAccel: fake);
  });
  tearDown(() => home.deleteSync(recursive: true));
  test('binding enumeration and merge preserve unsupported keys', () async {
    await fake.doRegister(['kwin', 'Window Close', 'KWin', 'Close window']);
    await fake.doRegister([
      'maprisma-launcher-0.desktop',
      '_launch',
      '',
      'Ours',
    ]);
    fake.keys['kwin:Window Close'] = [
      [0x10000041, 0, 0, 0],
      [65, 66],
      [0x20000041],
      [0],
    ];
    expect(await settings.available(), isTrue);
    final binding = (await settings.bindingKeys()).single;
    expect(
      [binding.$1, binding.$2, binding.$3],
      ['kde/kwin', 'Window Close', 'Close window'],
    );
    expect(binding.$4, ['<Super>a']);
    await settings.setStrv('kde/kwin', 'Window Close', ['<Shift>1']);
    expect(fake.keys['kwin:Window Close'], [
      [65, 66],
      [0x20000041],
      [0],
      [0x02000031],
    ]);
    await settings.setStrv('kwin', 'Window Close', []);
    expect(fake.keys['kwin:Window Close'], [
      [65, 66],
      [0x20000041],
      [0],
    ]);
    await expectLater(
      settings.setStrv('kwin', 'Window Close', ['bad-key']),
      throwsArgumentError,
    );
  });
  test('custom file round trip, quoting, partial update and reset', () async {
    const path = '${customBase}maprisma-launcher-0/';
    const command =
        r'''printf '%s' 'a b' '"' '$HOME' '`whoami`' '100%' 'back\slash' ''';
    await settings.writeCustom(path, {
      'name': 'A name',
      'command': command,
      'binding': '<Super><Shift>a',
    });
    expect(await settings.customPaths(), [path]);
    expect(await settings.readCustom(path), {
      'name': 'A name',
      'command': command,
      'binding': '<Super><Shift>a',
    });
    File ours() => Directory(settings.applications)
        .listSync()
        .whereType<File>()
        .singleWhere((f) => RegExp(r'/maprisma-launcher-0-[0-9a-f]{8}\.desktop$').hasMatch(f.path));
    final file = ours();
    expect(
      file.readAsStringSync(),
      contains('X-KDE-GlobalAccel-CommandShortcut=true'),
    );
    final component = file.uri.pathSegments.last;
    expect(desktopCommand(file.path, session)!.argv, ['sh', '-c', command]);
    expect(fake.registrations.values.single, [
      component,
      '_launch',
      'Maprisma Launcher',
      'A name',
    ]);
    await settings.writeCustom(path, {'name': 'Renamed'});
    expect((await settings.readCustom(path))['command'], command);
    expect(ours().path, file.path); // same command: same component
    // Another command is another component (KDE keeps a component's first service).
    await settings.writeCustom(path, {'command': 'echo other'});
    expect(file.existsSync(), isFalse);
    expect(fake.registrations.values.single[0], isNot(component));
    expect(await settings.customPaths(), [path]);
    await settings.resetCustom(path);
    expect(fake.registrations, isEmpty);
    expect(await settings.customPaths(), isEmpty);
  });
  test("the user's own KDE command shortcuts are bindings whose key can be taken", () async {
    Directory(settings.applications).createSync(recursive: true);
    File('${settings.applications}/user.desktop').writeAsStringSync(
      '[Desktop Entry]\nName=User command\nExec=echo hello\n',
    );
    await fake.doRegister([
      'user.desktop',
      '_launch',
      'Fallback label',
      'Launch',
    ]);
    fake.keys['user.desktop:_launch'] = [
      [0x10000042],
    ];
    expect(await settings.customPaths(), isEmpty);
    final b = (await settings.bindingKeys()).single;
    expect([b.$1, b.$2, b.$4], ['kde/user.desktop', '_launch', ['<Super>b']]);
    await settings.setStrv(b.$1, b.$2, []);
    expect(fake.keys['user.desktop:_launch'], isEmpty);
    await settings.setCustomPaths([]);
    expect(fake.registrations, isNotEmpty); // never removed: not ours
  });
  test('GnomeBackend saves app registration and removes stale files', () async {
    final backend = GnomeBackend(
      session,
      ConfigStore(session),
      settings,
      label: 'KDE Plasma',
    );
    final state = backend.clean({
      'apps': {
        'test': {
          'name': 'Test App',
          'launch': ['echo', 'hello world'],
          'shortcuts': [
            makeCombo(['SUPER', 'SHIFT'], 'A'),
          ],
        },
      },
    });
    await backend.save(state);
    final file = Directory(settings.applications).listSync().whereType<File>().single;
    expect(file.path, matches(RegExp(r'/maprisma-launcher-0-[0-9a-f]{8}\.desktop$')));
    final component = file.uri.pathSegments.last;
    expect(desktopCommand(file.path, session)!.argv, [
      'sh',
      '-c',
      "echo 'hello world'",
    ]);
    expect(fake.keys['$component:_launch'], [
      [0x12000041],
    ]);
    expect(fake.registrations.values.single[3], 'Test App');
    await backend.save(backend.clean(null));
    expect(file.existsSync(), isFalse);
  });
  test("a KDE key taken for an app is remembered across loads and given back", () async {
    await fake.doRegister(['kwin', 'Window Close', 'KWin', 'Close Window']);
    fake.keys['kwin:Window Close'] = [
      [0x12000041, 0, 0, 0], // Super+Shift+A
      [0x08000033, 0, 0, 0], // Alt+F4
    ];
    expect(cleanWhere('kde/kwin:Window Close'), 'kde/kwin:Window Close');
    expect(cleanWhere('kde/../x:y'), '');
    final store = ConfigStore(session);
    final backend = GnomeBackend(session, store, settings, label: 'KDE Plasma');
    final app = {
      'name': 'Test App',
      'launch': ['echo', 'hi'],
      // as assign() records it when the key belonged to KWin's action
      'shortcuts': [{...makeCombo(['SUPER', 'SHIFT'], 'A')!, 'taken_from': 'kde/kwin:Window Close'}],
    };
    final cleaned = backend.clean({'apps': {'test': app}});
    expect(((cleaned['apps'] as Map)['test']['shortcuts'] as List).single['taken_from'], 'kde/kwin:Window Close');
    await backend.save(cleaned);
    expect(fake.keys['kwin:Window Close']!.map((k) => k.first), [0x08000033]);
    // the state as the next start reads it still knows where the key came from
    final reloaded = backend.clean(store.readJson('shortcuts.json'));
    expect(reloaded['applied'], isNotEmpty);
    await backend.save(backend.clean({'apps': <String, dynamic>{}, 'applied': reloaded['applied']}));
    expect(fake.keys['kwin:Window Close']!.map((k) => k.first), containsAll([0x08000033, 0x12000041]));
  });

  test('a key KDE dropped (its service cache not yet updated) is registered again', () async {
    final dropping = _DroppingFake();
    final kde = KdeSettings(session, globalAccel: dropping)..retryPause = Duration.zero;
    const path = '${customBase}maprisma-launcher-0/';
    await kde.writeCustom(path, {'name': 'Term', 'command': 'cosmic-term', 'binding': '<Super>Return'});
    expect(dropping.registerCalls, 2); // the first one was dropped
    final c = dropping.keys.keys.single;
    expect(dropping.keys[c]!.single.first, 0x10000000 | 0x01000004);
  });

  test('missing session bus never falls back to process bus', () async {
    expect(await KdeSettings(session).available(), isFalse);
  });
}

/// kglobalaccel that ignores the first registration of each component, as
/// KDE does while its service cache does not know the new desktop file yet.
final class _DroppingFake extends FakeKGlobalAccel {
  final _seen = <String>{};
  var registerCalls = 0;
  @override
  Future<void> doRegister(List<String> action) async {
    registerCalls++;
    if (_seen.add(action[0])) return; // dropped
    await super.doRegister(action);
  }

  @override
  Future<void> setForeignShortcutKeys(List<String> action, List<List<int>> values) async {
    if (!registrations.containsKey(id(action))) return; // unknown: nothing happens
    await super.setForeignShortcutKeys(action, values);
  }
}
