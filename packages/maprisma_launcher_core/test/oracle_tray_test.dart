/// Tray Quit: menu parsing, find_quit, item_key and titles against tray.py,
/// and the busctl layer against a fake busctl (no real bus is touched).
library;

import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

List node(int id, Map<String, Object?> props, [List children = const []]) => [id, props, children];

final layouts = [
  // A normal app menu: mnemonics, a separator, a submenu, Quit at the end.
  [
    node(1, {'label': '_Show window'}),
    node(2, {'type': 'separator'}),
    node(3, {'label': 'Settings', 'children-display': 'submenu'}, [
      node(4, {'label': 'Notifications', 'toggle-type': 'checkmark', 'toggle-state': 1}),
      node(5, {'label': 'Hidden', 'visible': false}),
      node(6, {'label': 'Theme', 'toggle-type': 'radio', 'toggle-state': 0}),
    ]),
    node(7, {'label': 'Quit LM Studio'}),
  ],
  // Quit disabled, Exit in a submenu, Close later: Close wins.
  [
    node(1, {'label': 'Quit', 'enabled': false}),
    node(2, {'label': 'More'}, [node(3, {'label': 'Exit'})]),
    node(4, {'label': 'Quitter'}),
    node(5, {'label': 'Close all'}),
  ],
  // German, an empty label, a label that only looks like quit.
  [
    node(1, {'label': ''}),
    node(2, {'label': 'Beenden'}),
  ],
  [node(1, {'label': 'Exiting soon'}), node(2, {'label': 'a__b _c'}), node(9, {'label': 'Größe & Maß'})],
  const [],
];

void main() {
  test('tray menus, Quit, keys and titles equal tray.py', () async {
    final Map<String, List> spec = {
      'layouts': layouts,
      'keys': [
        ['steam', 'Steam', []],
        ['chrome_status_icon_1', 'LM Studio', []],
        ['chrome_status_icon_1', 'LM Studio', ['lm-studio']],
        ['', '', []],
        ['Electron', '', []],
        ['bad id!', 'Some App', []],
        ['steam', 'Steam', ['steam']],
        ['x' * 70, '', []],
      ],
      'titles': [
        {'Title': '_NordVPN'},
        {'Title': '', 'ToolTip': ['', [], 'LM Studio', 'body']},
        {'ToolTip': ['', []]},
        {},
      ],
      'labels': ['_Quit', 'a__b', '  _x_ ', '_\n', 'plain'],
    };
    final env = {...Platform.environment, 'LANG': 'C'};
    final repo = p.normalize(p.join(Directory.current.path, '../..'));
    final proc = await Process.start('/usr/bin/python3', ['-I', '-B', p.join(repo, 'tools/oracle.py'), 'tray'], environment: env);
    proc.stdin.write(jsonEncode(spec));
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    expect(await proc.exitCode, 0, reason: err);
    final expected = jsonDecode(out) as Map;
    final menus = [for (final l in layouts) menuNodes(l)];
    expect(menus, expected['menus']);
    expect([for (final m in menus) findQuit(m)?['id']], expected['quit']);
    expect([for (final k in spec['keys']!.cast<List>()) itemKey(k[0] as String, k[1] as String, {...(k[2] as List).cast<String>()})],
        expected['keys']);
    expect([for (final t in spec['titles']!.cast<Map>()) trayTitle(t)], expected['titles']);
    expect([for (final l in spec['labels']!.cast<String>()) cleanLabel(l)], expected['labels']);
    expect(expected['quit'], [7, 5, 2, null, null]);
  });

  test('bus names and paths from the bus are checked before busctl sees them', () {
    expect(Tray.split(':1.66/StatusNotifierItem'), (':1.66', '/StatusNotifierItem'));
    expect(Tray.split('org.kde.StatusNotifierItem-12-1'), ('org.kde.StatusNotifierItem-12-1', '/StatusNotifierItem'));
    expect(Tray.split('--user/x'), isNull);
    expect(Tray.split(':1.5/a b'), isNull);
    expect(Tray.split(':1.5/../x'), isNull);
    expect(Tray.split('-x'), isNull);
  });

  test('Quit goes through a fake busctl: matched by process, clicked by id, nothing else', () async {
    final dir = Directory.systemTemp.createTempSync('am-tray-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bin = Directory(p.join(dir.path, 'bin'))..createSync();
    final log = p.join(dir.path, 'calls.log');
    // A fake proc entry for the icon's owner, ours.
    final procDir = Directory(p.join(dir.path, 'proc', '4242'))..createSync(recursive: true);
    Link(p.join(procDir.path, 'exe')).createSync('/opt/LM Studio/lm-studio');
    File(p.join(procDir.path, 'cmdline')).writeAsStringSync('/opt/LM Studio/lm-studio\x00--x\x00');
    File(p.join(procDir.path, 'environ')).writeAsStringSync('APPIMAGE=/home/u/LM-Studio.AppImage\x00');
    final layout = {
      'type': 'u(ia{sv}av)',
      'data': [3, [0, {}, [
        {'type': '(ia{sv}av)', 'data': [11, {'label': {'type': 's', 'data': 'Show'}}, []]},
        {'type': '(ia{sv}av)', 'data': [12, {'label': {'type': 's', 'data': '_Quit LM Studio'}}, []]},
      ]]],
    };
    final script = File(p.join(bin.path, 'busctl'))
      ..writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$*" >> '$log'
case "\$*" in
  *RegisteredStatusNotifierItems*) echo '{"type":"as","data":[":1.9/StatusNotifierItem","bad name/x"]}' ;;
  *GetConnectionUnixProcessID*) echo '{"type":"u","data":[4242]}' ;;
  *GetAll*) echo '{"type":"a{sv}","data":[{"Id":{"type":"s","data":"chrome_status_icon_1"},"Title":{"type":"s","data":""},"Menu":{"type":"o","data":"/MenuBar"}}]}' ;;
  *GetLayout*) echo '${jsonEncode(layout)}' ;;
  *AboutToShow*) echo '{"type":"b","data":[false]}' ;;
  *Event*) echo '' ;;
  *) exit 1 ;;
esac
''');
    Process.runSync('chmod', ['755', script.path]);
    final tray = Tray(Session(environment: {'PATH': bin.path, 'HOME': dir.path}), proc: p.join(dir.path, 'proc'));
    final app = {'desktop_id': 'lm-studio', 'name': 'LM Studio', 'exec': '"/opt/LM Studio/lm-studio" %U'};
    final found = await tray.quitFor(app);
    expect(found, isNotNull);
    expect(found!.$1['tray_programs'], {'lm-studio'});
    expect(found.$2['label'], 'Quit LM Studio');
    expect(await tray.click(found.$1, found.$2['id'] as int), isTrue);
    final calls = File(log).readAsLinesSync();
    expect(calls.where((c) => c.contains('bad name')), isEmpty);
    expect(calls.every((c) => c.startsWith('--user --json=short --timeout=1.5 -- ')), isTrue);
    expect(calls.last, '--user --json=short --timeout=1.5 -- call :1.9 /MenuBar com.canonical.dbusmenu Event isvu 12 clicked i 0 0');
    // A shared interpreter or Electron runtime, or a desktop entry's Exec
    // program, never claims the icon (only argv of AppImages/CLI tools does).
    expect(Tray.belongsTo(found.$1, {'desktop_id': 'x', 'name': 'X', 'exec': 'python3 /opt/x.py'}), isFalse);
    expect(Tray.belongsTo({...found.$1, 'tray_programs': {'electron34'}},
        {'desktop_id': 'y', 'name': 'Y', 'exec': 'electron34 /usr/lib/y/app.asar'}), isFalse);
    expect(Tray.belongsTo({...found.$1, 'tray_programs': {'python3'}},
        {'desktop_id': 'z', 'name': 'Z', 'exec': 'env A=1 python3 z.py'}), isFalse);
    expect(Tray.belongsTo({...found.$1, 'tray_programs': {'lm-studio'}},
        {'desktop_id': 'lms', 'name': 'LMS', 'exec': '', 'argv': ['/home/u/Apps/lm-studio.AppImage']}), isTrue);
    // Another app has no icon: no Quit.
    expect(await tray.quitFor({'desktop_id': 'gimp', 'name': 'GIMP', 'exec': 'gimp %U'}), isNull);
  });
}
