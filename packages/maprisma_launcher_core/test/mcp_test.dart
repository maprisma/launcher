/// Maprisma Launcher MCP server (JSON-RPC 2.0) and shared tool dispatcher tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late CoreService core;

  void addDesktop(String id, String name, {String comment = '', String categories = 'Graphics;'}) {
    final appsDir = Directory(p.join(home.path, 'data/applications'))..createSync(recursive: true);
    File(p.join(appsDir.path, '$id.desktop')).writeAsStringSync(
      '[Desktop Entry]\nType=Application\nName=$name\nComment=$comment\nExec=/bin/true\nCategories=$categories\n',
    );
  }

  Future<Map<String, Object?>?> rpc(Object? frame) => launcherMcpReply(frame, core);

  Future<Map<String, dynamic>> callTool(String name, [Map<String, Object?> args = const {}]) async {
    final reply = await rpc({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    });
    expect(reply, isNotNull);
    expect(reply!['error'], isNull, reason: '$reply');
    final result = reply['result'] as Map;
    final text = ((result['content'] as List).single as Map)['text'] as String;
    return {
      'isError': result['isError'] == true,
      'data': jsonDecode(text) as Map<String, dynamic>,
    };
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('launcher-mcp-');
    addDesktop('photocraft', 'PhotoCraft', comment: 'Photo editor');
    addDesktop('vectorcraft', 'VectorCraft', comment: 'Vector editor');
    addDesktop('pdfcraft', 'PDFCraft', comment: 'PDF studio');
    addDesktop('firefox', 'Firefox', comment: 'Web browser', categories: 'Network;');
    core = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '/usr/bin:/bin',
        'XDG_CONFIG_HOME': p.join(home.path, 'config'),
        'XDG_DATA_HOME': p.join(home.path, 'data'),
        'XDG_DATA_DIRS': p.join(home.path, 'none'),
        'XDG_STATE_HOME': p.join(home.path, 'state'),
        'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
      },
    );
  });

  tearDown(() {
    core.dispose();
    home.deleteSync(recursive: true);
  });

  test('MCP protocol handshake, ping, notifications, and validation', () async {
    final init = await rpc({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}});
    expect((init!['result'] as Map)['protocolVersion'], '2024-11-05');
    expect(await rpc({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), isNull);
    expect((await rpc({'jsonrpc': '2.0', 'id': 'p1', 'method': 'ping'}))!['result'], isEmpty);

    final list = await rpc({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    final toolNames = [
      for (final t in (list!['result'] as Map)['tools'] as List) (t as Map)['name'],
    ];
    expect(toolNames, containsAll([
      'launcher_apps_list',
      'launcher_groups_list',
      'launcher_groups_create',
      'launcher_groups_rename',
      'launcher_groups_delete',
      'launcher_groups_move_apps',
      'launcher_groups_reorder',
      'launcher_groups_toggle',
      'launcher_apps_hide',
      'launcher_dock_pin',
      'launcher_settings_get',
      'launcher_settings_set',
    ]));

    // Unknown tool & unexpected parameters are rejected cleanly.
    final badTool = await rpc({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'nope', 'arguments': {}},
    });
    expect((badTool!['error'] as Map)['code'], -32602);

    final badParam = await callTool('launcher_groups_list', {'bogus': true});
    expect(badParam['isError'], isTrue);
    expect((badParam['data'] as Map)['code'], 'invalid_request');
  });

  test('groups lifecycle and moving Craft apps into Craft group via MCP tools', () async {
    // Create Craft group.
    final created = await callTool('launcher_groups_create', {'name': 'Craft'});
    expect(created['isError'], isFalse, reason: '$created');
    final craftId = (created['data'] as Map)['id'] as String;

    // List Craft apps via query.
    final found = await callTool('launcher_apps_list', {'query': 'craft'});
    expect(found['isError'], isFalse);
    final craftApps = ((found['data'] as Map)['apps'] as List).cast<Map>();
    expect(craftApps, hasLength(3));

    // Move all Craft apps into Craft group by display name.
    final moved = await callTool('launcher_groups_move_apps', {
      'apps': [for (final a in craftApps) a['desktop_id'] as String],
      'group': 'Craft',
    });
    expect(moved['isError'], isFalse, reason: '$moved');
    expect((moved['data'] as Map)['group'], craftId);
    expect((moved['data'] as Map)['count'], 3);

    // Verify via launcher_apps_list(group: 'Craft') and launcher_groups_list(include_apps: true).
    final inCraft = await callTool('launcher_apps_list', {'group': 'Craft'});
    expect(((inCraft['data'] as Map)['apps'] as List), hasLength(3));

    final groupsList = await callTool('launcher_groups_list', {'include_apps': true});
    final craftGroup = ((groupsList['data'] as Map)['groups'] as List)
        .cast<Map>()
        .firstWhere((g) => g['id'] == craftId);
    expect(craftGroup['display_name'], 'Craft');
    expect(craftGroup['count'], 3);

    // Rename, reorder, toggle, then delete.
    final renamed = await callTool('launcher_groups_rename', {
      'group': 'Craft',
      'name': 'ArtCraft',
    });
    expect(renamed['isError'], isFalse, reason: '$renamed');
    expect((renamed['data'] as Map)['name'], 'ArtCraft');

    final reordered = await callTool('launcher_groups_reorder', {
      'group': 'ArtCraft',
      'target': 'Office',
      'after': false,
    });
    expect(reordered['isError'], isFalse);
    expect((((reordered['data'] as Map)['groups'] as List).first as Map)['id'], craftId);

    final toggled = await callTool('launcher_groups_toggle', {'group': 'ArtCraft'});
    expect(toggled['isError'], isFalse);
    expect((toggled['data'] as Map)['collapsed'], isTrue);

    // Move with create: true creates a brand-new group automatically.
    final createdOnMove = await callTool('launcher_groups_move_apps', {
      'apps': ['firefox'],
      'group': 'Browsers',
      'create': true,
    });
    expect(createdOnMove['isError'], isFalse);
    expect((createdOnMove['data'] as Map)['created'], isTrue);
    expect((createdOnMove['data'] as Map)['group_name'], 'Browsers');

    // Delete ArtCraft.
    final deleted = await callTool('launcher_groups_delete', {'group': 'ArtCraft'});
    expect(deleted['isError'], isFalse);
    expect((deleted['data'] as Map)['deleted'], craftId);
  });

  test('hide, dock pin, and settings tools work via MCP', () async {
    final hidden = await callTool('launcher_apps_hide', {
      'apps': ['firefox'],
      'hidden': true,
    });
    expect(hidden['isError'], isFalse);
    final hiddenList = await callTool('launcher_apps_list', {'hidden': true});
    expect(((hiddenList['data'] as Map)['apps'] as List).single['desktop_id'], 'firefox');

    final pinned = await callTool('launcher_dock_pin', {
      'apps': ['photocraft', 'vectorcraft'],
      'pinned': true,
    });
    expect(pinned['isError'], isFalse);
    expect((pinned['data'] as Map)['pinned'], containsAll(['photocraft', 'vectorcraft']));

    final setSkin = await callTool('launcher_settings_set', {'key': 'skin', 'value': 'cozy'});
    expect(setSkin['isError'], isFalse);
    expect((setSkin['data'] as Map)['skin'], 'cozy');
    final got = await callTool('launcher_settings_get');
    expect((got['data'] as Map)['skin'], 'cozy');
  });

  test('stdio MCP subprocess handles JSON-RPC over stdin/stdout and persists config', () async {
    final configDir = p.join(home.path, 'mcp-config');
    final proc = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        p.absolute('bin/maprisma_launcher_core.dart'),
        'mcp',
        '--config-dir',
        configDir,
      ],
      environment: {
        'HOME': home.path,
        'PATH': '/usr/bin:/bin',
        'XDG_DATA_HOME': p.join(home.path, 'data'),
        'XDG_DATA_DIRS': p.join(home.path, 'none'),
        'MAPRISMA_LAUNCHER_DESKTOP': 'generic',
      },
      includeParentEnvironment: false,
    );
    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    final lines = proc.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final it = StreamIterator(lines);

    Future<Map<String, dynamic>> send(Map<String, Object?> frame) async {
      proc.stdin.writeln(jsonEncode(frame));
      await proc.stdin.flush();
      expect(await it.moveNext(), isTrue, reason: 'unexpected EOF');
      return jsonDecode(it.current) as Map<String, dynamic>;
    }

    final init = await send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}});
    expect((init['result'] as Map)['protocolVersion'], '2024-11-05');
    proc.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    await proc.stdin.flush();

    final create = await send({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {
        'name': 'launcher_groups_create',
        'arguments': {'name': 'Craft', 'apps': ['photocraft', 'vectorcraft']},
      },
    });
    final payload = jsonDecode((((create['result'] as Map)['content'] as List).single as Map)['text'] as String) as Map;
    expect(payload['name'], 'Craft');
    expect((payload['moved'] as List), hasLength(2));

    await proc.stdin.close();
    expect(await proc.exitCode, 0, reason: await stderrFuture);
    await it.cancel();

    // Persisted on disk in --config-dir.
    final saved = jsonDecode(File(p.join(configDir, 'groups.json')).readAsStringSync()) as Map;
    final members = (saved['apps'] as Map)['members'] as Map;
    expect(members['photocraft'], payload['id']);
    expect(members['vectorcraft'], payload['id']);
  });
}
