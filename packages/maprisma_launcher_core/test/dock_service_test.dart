/// The dock's routes on a fixture home: Omarchy with a fake hyprctl (its
/// window list from clients.json, every dispatch logged) and a fake uwsm-app;
/// a generic desktop where the dock is not available.
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const fakeHyprctl = r'''#!/bin/sh
here=$(dirname "$0")
printf '%s\n' "$*" >> "$here/hyprctl.log"
case "$1" in
  clients) cat "$here/clients.json" ;;
  dispatch) echo ok ;;
  *) exit 1 ;;
esac
''';

void writeExec(String path, String text) {
  File(path).writeAsStringSync(text);
  Process.runSync('chmod', ['755', path]);
}

final class Fixture {
  Fixture({bool omarchy = true}) {
    home = Directory.systemTemp.createTempSync('am-dock-');
    bin = p.join(home.path, 'bin');
    Directory(bin).createSync();
    for (final tool in ['sh', 'cat', 'dirname']) {
      final found = whichIn(tool, Platform.environment);
      if (found != null) Link(p.join(bin, tool)).createSync(found);
    }
    for (final program in ['firefox', 'nautilus']) {
      writeExec(p.join(bin, program), '#!/bin/sh\n');
    }
    writeExec(p.join(bin, 'hyprctl'), fakeHyprctl);
    writeExec(p.join(bin, 'uwsm-app'), '#!/bin/sh\nprintf "%s\\n" "\$*" >> "${p.join(bin, 'uwsm.log')}"\n');
    final apps = p.join(home.path, 'data/applications');
    Directory(apps).createSync(recursive: true);
    File(p.join(apps, 'firefox.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox %u\nStartupWMClass=firefox\n'
      'Actions=new-window;\n[Desktop Action new-window]\nName=New Window\nExec=firefox --new-window\n',
    );
    File(p.join(apps, 'files.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=Files\nExec=nautilus --new-window\nStartupWMClass=org.gnome.Nautilus\n',
    );
    final omarchyDir = Directory(p.join(home.path, 'omarchy'))..createSync();
    clients([]);
    core = CoreService(
      executable: p.join(bin, 'maprisma-launcher'),
      environment: {
        'HOME': home.path,
        'PATH': bin,
        'XDG_DATA_HOME': p.join(home.path, 'data'),
        'XDG_DATA_DIRS': p.join(home.path, 'none'),
        'XDG_CONFIG_HOME': p.join(home.path, '.config'),
        if (omarchy) ...{
          'MAPRISMA_LAUNCHER_DESKTOP': 'omarchy',
          'OMARCHY_PATH': omarchyDir.path,
          'HYPRLAND_INSTANCE_SIGNATURE': 'test',
        } else
          'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
      },
    );
  }

  late final Directory home;
  late final String bin;
  late final CoreService core;
  String get firefox => p.join(home.path, 'data/applications/firefox.desktop');
  String get files => p.join(home.path, 'data/applications/files.desktop');

  void clients(List<Map> list) => File(p.join(bin, 'clients.json')).writeAsStringSync(jsonEncode(list));
  List<String> log(String name) {
    final f = File(p.join(bin, name));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final reply = jsonDecode(
      await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})),
    ) as Map;
    if (reply['error'] case final Map e) throw ServiceError('${e['code']}', e['message'] as String?);
    return Map<String, dynamic>.from(reply['result'] as Map);
  }

  Future<String> code(String method, Map<String, dynamic> params) async {
    try {
      await call(method, params);
      return 'ok';
    } on ServiceError catch (e) {
      return e.code;
    }
  }

  void dispose() => home.deleteSync(recursive: true);
}

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.dispose());

  test('state: settings, the bar edge left out, sizes, availability', () async {
    var state = await f.call('dock.state');
    expect(state['settings'], containsPair('dock_enabled', false));
    expect(state['edge'], 'bottom');
    expect(state['sizes'], {'band': 48, 'item': 46, 'room': 48, 'grow': 0});
    expect(state['reason'], layerShellInstalled() ? isNull : 'no_layer_shell');
    // The bar at the bottom: the dock moves to the top.
    final shell = File(p.join(f.home.path, '.config/omarchy/shell.json'))..createSync(recursive: true);
    shell.writeAsStringSync('{"bar": {"position": "bottom"}}');
    state = await f.call('dock.set', {'key': 'dock_icon_size', 'value': 56});
    expect([state['bar'], state['edge']], ['bottom', 'top']);
    expect(state['sizes'], {'band': 48, 'item': 70, 'room': 70, 'grow': 0});
    expect(await f.code('dock.set', {'key': 'dock_icon_size', 'value': 57}), 'bad_params');
    expect(await f.code('dock.set', {'key': 'dock_pinned', 'value': ['x']}), 'bad_params');
    expect(await f.code('dock.set', {'key': 'language', 'value': 'de'}), 'bad_params');
    await f.call('dock.set', {'key': 'dock_enabled', 'value': true});
    state = await f.call('dock.reset');
    expect(state['settings'], containsPair('dock_enabled', false));
    expect(state['settings'], containsPair('dock_icon_size', 32));
    expect((state['watch'] as List).first, endsWith('maprisma-launcher/settings.json'));
  });

  test('items: pinned first, then running; activate focuses or launches; close', () async {
    await f.call('apps.list');
    await f.call('dock.pin', {'key': f.files});
    f.clients([
      {'address': '0x1a', 'class': 'firefox', 'focusHistoryID': 0, 'mapped': true},
      {'address': '0x2b', 'class': 'firefox', 'focusHistoryID': 2},
      {'address': 'bad', 'class': 'firefox', 'focusHistoryID': 1},
      {'address': '0x3c', 'class': 'other', 'focusHistoryID': 3},
    ]);
    final items = await f.call('dock.items', {'rescan': true});
    final list = (items['items'] as List).cast<Map>();
    expect([for (final i in list) [i['name'], i['pinned'], i['windows']]], [
      ['Files', true, []],
      ['Firefox', false, ['0x1a', '0x2b']],
    ]);
    expect(list[1]['new_window_action'], isTrue);
    expect(list[1]['actions'], [{'id': 'new-window', 'name': 'New Window'}]);
    expect(items['active'], '0x1a');

    // Firefox is focused: the click goes to its next window; Files is not running: it starts.
    expect(await f.call('dock.activate', {'key': f.firefox}), {'focused': '0x2b'});
    expect(f.log('hyprctl.log').last, 'dispatch hl.dsp.focus({window = "address:0x2b"})');
    expect(await f.call('dock.activate', {'key': f.files}), {'started': true});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(f.log('uwsm.log'), ['-- ${f.files}']);

    expect(await f.call('dock.close', {'key': f.firefox}), {'closed': 2});
    expect(f.log('hyprctl.log').where((l) => l.contains('window.close')).toList(), [
      'dispatch hl.dsp.window.close({window = "address:0x1a"})',
      'dispatch hl.dsp.window.close({window = "address:0x2b"})',
    ]);
    expect(await f.code('dock.activate', {'key': '/nope.desktop'}), 'unknown_app');
  });

  test('pin, unpin and reorder by desktop id', () async {
    await f.call('apps.list');
    expect(await f.call('dock.pin', {'key': f.firefox}), {'pinned': ['firefox']});
    expect(await f.call('dock.pin', {'key': f.files}), {'pinned': ['firefox', 'files']});
    expect(await f.call('dock.move', {'id': 'files', 'target': 'firefox'}),
        {'pinned': ['files', 'firefox']});
    expect(await f.code('dock.move', {'id': 'evil', 'target': 'firefox'}), 'not_found');
    expect(await f.call('dock.pin', {'key': f.firefox, 'pinned': false}), {'pinned': ['files']});
    // Other settings stay.
    await f.call('settings.set', {'key': 'language', 'value': 'de'});
    await f.call('dock.pin', {'key': f.firefox});
    expect((await f.call('settings.get'))['language'], 'de');
  });

  test('start: only when switched on and available; the manager button', () async {
    writeExec(p.join(f.bin, 'maprisma-launcher'), '#!/bin/sh\nprintf "%s\\n" "\$*" >> "${p.join(f.bin, 'self.log')}"\n');
    expect(await f.call('dock.start'), containsPair('started', false));
    await f.call('dock.set', {'key': 'dock_enabled', 'value': true});
    final started = await f.call('dock.start');
    expect(started['started'], layerShellInstalled());
    expect(await f.call('dock.open_manager'), {'started': true});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(f.log('self.log'), [if (layerShellInstalled()) '--dock', '--toggle']);
  });

  test('generic desktop: not available', () async {
    final g = Fixture(omarchy: false);
    addTearDown(g.dispose);
    final state = await g.call('dock.state');
    expect([state['available'], state['reason']], [false, 'not_omarchy']);
  });
}
