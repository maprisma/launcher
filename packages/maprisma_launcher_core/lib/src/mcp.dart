/// Local stdio MCP server (JSON-RPC 2.0) and shared internal-management tools
/// for Maprisma Launcher (`maprisma-launcher mcp` / `maprisma-launcher-core mcp`).
///
/// The same tool catalog and dispatcher power both external MCP clients (over
/// stdin/stdout) and Ask AI's internal management plans (`action: "manage"`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'core.dart';
import 'groups.dart' as groups;
import 'protocol.dart';

/// Maximum bytes accepted for one JSON-RPC line on stdin.
const launcherMcpMaxLine = 256 * 1024;

/// Usage banner kept readable in the compiled binary so MCP scanners detect
/// the server and its `mcp` subcommand without executing it.
const launcherMcpUsage =
    'Usage: maprisma-launcher mcp [--config-dir PATH]\n'
    '       maprisma-launcher-core mcp [--config-dir PATH]';

const _int64Max = 0x7fffffffffffffff;
const _int64Min = -0x8000000000000000;

/// Settings keys Ask AI is permitted to propose changing via `launcher_settings_set`.
const askAiSafeSettings = <String>{
  'view',
  'wide_layout',
  'corners',
  'skin',
  'running_first',
  'view_buttons',
  'filter_field',
  'window_mode',
  'close_outside',
  'close_after_launch',
  'github_source',
  'language',
  'icon_size',
};

/// MCP tools that Ask AI may propose inside an `"action": "manage"` plan.
const askAiManageToolNames = <String>{
  'launcher_groups_create',
  'launcher_groups_rename',
  'launcher_groups_delete',
  'launcher_groups_move_apps',
  'launcher_groups_reorder',
  'launcher_groups_toggle',
  'launcher_dock_pin',
  'launcher_settings_set',
};

/// Tool definitions exposed by Maprisma Launcher's MCP server.
const List<Map<String, Object?>> launcherMcpTools = [
  {
    'name': 'launcher_apps_list',
    'description':
        'List installed desktop apps known to Maprisma Launcher, with each app\'s key, desktop_id, name, description, group, group_name, origin, hidden, running, and pinned status. Optional filters: query, group, hidden, running.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'Case-insensitive substring match against app name, description, or desktop_id.',
        },
        'group': {
          'type': 'string',
          'description': 'Filter to a group by id (e.g. "g3", "office", "other") or display name (e.g. "Craft").',
        },
        'hidden': {
          'type': 'boolean',
          'description': 'When true, return only hidden apps; when false, exclude hidden apps. Omit to include all.',
        },
        'running': {
          'type': 'boolean',
          'description': 'When true, return only currently running apps.',
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_apps_hide',
    'description':
        'Hide or unhide one or more installed apps from the Maprisma Launcher list (apps stay installed).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'apps': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'App keys or desktop_ids to hide or unhide.',
        },
        'hidden': {
          'type': 'boolean',
          'description': 'true to hide from the list, false to show again.',
        },
      },
      'required': ['apps', 'hidden'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_apps_launch',
    'description': 'Launch an installed app by key or desktop_id.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'app': {
          'type': 'string',
          'description': 'App key or desktop_id.',
        },
        'action': {
          'type': 'string',
          'description': 'Optional desktop entry action id.',
        },
      },
      'required': ['app'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_list',
    'description':
        'List all app groups in display order (id, name, display_name, builtin, new, collapsed, count, and optionally member apps) plus the implicit "other" group.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'include_apps': {
          'type': 'boolean',
          'description': 'Include each group\'s member apps (key, desktop_id, name).',
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_create',
    'description':
        'Create a new app group in Maprisma Launcher, optionally placing apps into it immediately.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': 'Name for the new group (1 to 40 characters, must not duplicate an existing group).',
        },
        'apps': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Optional app keys or desktop_ids to move into the newly created group.',
        },
      },
      'required': ['name'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_rename',
    'description': 'Rename an existing app group (by id or current display name).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'group': {
          'type': 'string',
          'description': 'Existing group id (e.g. "g2", "office") or current display name.',
        },
        'name': {
          'type': 'string',
          'description': 'New name for the group (1 to 40 characters).',
        },
      },
      'required': ['group', 'name'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_delete',
    'description':
        'Delete an app group (by id or display name). Apps in it return to their default group or Other.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'group': {
          'type': 'string',
          'description': 'Group id or display name to delete.',
        },
      },
      'required': ['group'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_move_apps',
    'description':
        'Move one or more apps into a group (by group id, display name, or "other"). Set create: true to create the group first if it does not exist.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'apps': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'App keys or desktop_ids to move into the group.',
        },
        'group': {
          'type': 'string',
          'description': 'Target group id, display name (e.g. "Craft"), or "other".',
        },
        'create': {
          'type': 'boolean',
          'description': 'If true and the named group does not exist yet, create it before moving the apps.',
        },
      },
      'required': ['apps', 'group'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_reorder',
    'description':
        'Reorder a group either relative to another group (target + after) or one step up/down (delta: -1 or 1).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'group': {
          'type': 'string',
          'description': 'Group id or display name to move.',
        },
        'target': {
          'type': 'string',
          'description': 'Target group id or display name to place this group before or after.',
        },
        'after': {
          'type': 'boolean',
          'description': 'Place after target when true, before target when false (default false).',
        },
        'delta': {
          'type': 'integer',
          'enum': [-1, 1],
          'description': 'Move one position up (-1) or down (1) when target is omitted.',
        },
      },
      'required': ['group'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_groups_toggle',
    'description': 'Collapse or expand a group section in Maprisma Launcher.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'group': {
          'type': 'string',
          'description': 'Group id or display name (or "other").',
        },
      },
      'required': ['group'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_dock_state',
    'description': 'Read Maprisma Launcher dock availability, settings, and pinned app desktop_ids.',
    'inputSchema': {
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_dock_pin',
    'description': 'Pin or unpin one or more apps on the Maprisma Launcher dock.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'apps': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'App keys or desktop_ids to pin or unpin.',
        },
        'pinned': {
          'type': 'boolean',
          'description': 'true to pin, false to unpin.',
        },
      },
      'required': ['apps', 'pinned'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_shortcuts_list',
    'description': 'List launcher keyboard shortcuts for all apps or one specific app.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'app': {
          'type': 'string',
          'description': 'Optional app key or desktop_id.',
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_settings_get',
    'description': 'Read current Maprisma Launcher settings (view, wide_layout, skin, corners, etc.).',
    'inputSchema': {
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
  },
  {
    'name': 'launcher_settings_set',
    'description': 'Change a Maprisma Launcher setting (e.g. view, wide_layout, skin, corners, running_first, close_after_launch, close_outside, window_mode, github_source, language).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'key': {
          'type': 'string',
          'description': 'Setting key name.',
        },
        'value': {
          'description': 'New value for the setting.',
        },
      },
      'required': ['key', 'value'],
      'additionalProperties': false,
    },
  },
];

final Map<String, Set<String>> _allowedKeysByTool = {
  for (final tool in launcherMcpTools)
    tool['name']! as String: {
      for (final key
          in ((tool['inputSchema']! as Map)['properties']! as Map).keys)
        key as String,
    },
};

/// Compact description of the MCP tools Ask AI may propose inside `"action": "manage"`.
String askAiManageToolsPrompt() {
  final lines = <String>[];
  for (final tool in launcherMcpTools) {
    final name = tool['name'] as String;
    if (!askAiManageToolNames.contains(name)) continue;
    final schema = tool['inputSchema'] as Map;
    final props = schema['properties'] as Map;
    final req = (schema['required'] as List? ?? const []).cast<String>().toSet();
    final fields = [
      for (final e in props.entries)
        '${e.key}${req.contains(e.key) ? '' : '?'}',
    ].join(', ');
    lines.add('- $name($fields): ${tool['description']}');
  }
  return lines.join('\n');
}

/// Parse `mcp [--config-dir PATH]` CLI arguments.
/// Returns the normalized config directory path or null for the default store.
String? parseLauncherMcpArgs(List<String> args) {
  if (args.isEmpty || (args.first != 'mcp' && args.first != '--mcp')) {
    throw const FormatException('Expected mcp');
  }
  String? configDir;
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    String raw;
    if (arg == '--config-dir') {
      if (configDir != null || i + 1 >= args.length) {
        throw const FormatException('Missing or duplicate --config-dir');
      }
      raw = args[++i];
    } else if (arg.startsWith('--config-dir=')) {
      if (configDir != null) {
        throw const FormatException('Duplicate --config-dir');
      }
      raw = arg.substring('--config-dir='.length);
    } else {
      throw FormatException('Unknown option: $arg');
    }
    if (raw.trim().isEmpty || raw.contains('\x00')) {
      throw const FormatException('Invalid --config-dir path');
    }
    configDir = p.normalize(p.absolute(raw));
  }
  return configDir;
}

bool _validId(Object? id) =>
    (id is int && id >= _int64Min && id <= _int64Max) ||
    (id is String && id.length <= 256);

Map<String, Object?> _toolText(
  Map<String, dynamic> payload, {
  bool error = false,
}) => {
  'content': [
    {'type': 'text', 'text': jsonEncode(payload)},
  ],
  'isError': error,
};

/// Resolve a group reference (id, "other", or case-insensitive display name) to a group id.
String? resolveGroupRef(String ref, groups.GroupData data) {
  final trimmed = ref.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower == groups.other) return groups.other;
  for (final g in data['groups'] as List) {
    final id = g['id'] as String;
    if (id == trimmed || id.toLowerCase() == lower) return id;
  }
  for (final g in data['groups'] as List) {
    final id = g['id'] as String;
    final shown = groups.displayName(id, data).toLowerCase();
    if (shown == lower) return id;
  }
  return null;
}

/// Resolve an app reference (exact app key or desktop_id) against the scanned apps.
String? resolveAppRef(String ref, List<Map<String, dynamic>> apps) {
  if (ref.isEmpty) return null;
  for (final app in apps) {
    if (app['key'] == ref) return app['key'] as String;
  }
  for (final app in apps) {
    if (app['desktop_id'] == ref) return app['key'] as String;
  }
  final lower = ref.toLowerCase();
  final matches = [
    for (final app in apps)
      if ('${app['desktop_id'] ?? ''}'.toLowerCase() == lower)
        app['key'] as String,
  ];
  return matches.length == 1 ? matches.single : null;
}

/// Execute one validated Launcher MCP tool against [core].
Future<Map<String, dynamic>> callLauncherMcpTool(
  CoreService core,
  String name,
  Map<String, dynamic> arguments,
) async {
  final allowed = _allowedKeysByTool[name];
  if (allowed == null) {
    throw const FormatException('Unknown tool');
  }
  final unknown = arguments.keys.where((k) => !allowed.contains(k));
  if (unknown.isNotEmpty) {
    throw FormatException('Unexpected parameter: ${unknown.first}');
  }

  Future<List<Map<String, dynamic>>> ensureApps() async {
    final listed = await core.routes['apps.list']!(const {});
    return [
      for (final a in listed['apps'] as List) Map<String, dynamic>.from(a as Map),
    ];
  }

  List<String> requireStringList(String field, {bool allowEmpty = false}) {
    final raw = arguments[field];
    if (raw is! List || raw.length > 500 || raw.any((e) => e is! String || e.isEmpty)) {
      throw FormatException('$field must be a list of non-empty strings');
    }
    if (!allowEmpty && raw.isEmpty) {
      throw FormatException('$field must not be empty');
    }
    return raw.cast<String>();
  }

  String requireString(String field) {
    final raw = arguments[field];
    if (raw is! String || raw.trim().isEmpty || raw.length > 4096) {
      throw FormatException('$field must be a non-empty string');
    }
    return raw;
  }

  bool requireBool(String field) {
    final raw = arguments[field];
    if (raw is! bool) throw FormatException('$field must be a boolean');
    return raw;
  }

  List<String> resolveApps(List<String> refs, List<Map<String, dynamic>> apps) {
    final resolved = <String>[];
    final missing = <String>[];
    final seen = <String>{};
    for (final ref in refs) {
      final key = resolveAppRef(ref, apps);
      if (key == null) {
        missing.add(ref);
      } else if (seen.add(key)) {
        resolved.add(key);
      }
    }
    if (missing.isNotEmpty) {
      throw ServiceError('unknown_app', 'Unknown app(s): ${missing.join(', ')}');
    }
    return resolved;
  }

  switch (name) {
    case 'launcher_apps_list':
      final query = arguments['query'];
      if (query != null && query is! String) {
        throw const FormatException('query must be a string');
      }
      final groupFilter = arguments['group'];
      if (groupFilter != null && groupFilter is! String) {
        throw const FormatException('group must be a string');
      }
      final hiddenFilter = arguments['hidden'];
      if (hiddenFilter != null && hiddenFilter is! bool) {
        throw const FormatException('hidden must be a boolean');
      }
      final runningFilter = arguments['running'];
      if (runningFilter != null && runningFilter is! bool) {
        throw const FormatException('running must be a boolean');
      }
      final apps = await ensureApps();
      final groupData = core.loadGroupsData();
      final runningResult = await core.routes['apps.running']!(const {});
      final runningSet = (runningResult['running'] as List).cast<String>().toSet();
      final pinnedSet = core.dock.pinned().toSet();
      String? wantedGroupId;
      if (groupFilter is String && groupFilter.trim().isNotEmpty) {
        wantedGroupId = resolveGroupRef(groupFilter, groupData);
        if (wantedGroupId == null) {
          throw ServiceError('unknown_group', 'Unknown group: $groupFilter');
        }
      }
      final q = (query as String? ?? '').trim().toLowerCase();
      final out = <Map<String, dynamic>>[];
      for (final app in apps) {
        final key = app['key'] as String;
        final gid = app['group'] as String? ?? groups.other;
        final isHidden = app['hidden'] == true;
        final isRunning = runningSet.contains(key);
        if (wantedGroupId != null && gid != wantedGroupId) continue;
        if (hiddenFilter is bool && isHidden != hiddenFilter) continue;
        if (runningFilter == true && !isRunning) continue;
        if (q.isNotEmpty) {
          final hay =
              '${app['name'] ?? ''} ${app['description'] ?? ''} ${app['desktop_id'] ?? ''}'
                  .toLowerCase();
          if (!hay.contains(q)) continue;
        }
        out.add({
          'key': key,
          'desktop_id': app['desktop_id'],
          'name': app['name'],
          'description': app['description'] ?? '',
          'group': gid,
          'group_name': groups.displayName(gid, groupData),
          'origin': app['origin'],
          'hidden': isHidden,
          'running': isRunning,
          'pinned': pinnedSet.contains(app['desktop_id']),
        });
      }
      return {
        'apps': out,
        'count': out.length,
        'groups': _groupsSummary(groupData),
      };

    case 'launcher_apps_hide':
      final refs = requireStringList('apps');
      final hidden = requireBool('hidden');
      final apps = await ensureApps();
      final keys = resolveApps(refs, apps);
      for (final key in keys) {
        await core.routes['apps.hide']!({'key': key, 'hidden': hidden});
      }
      return {'apps': keys, 'hidden': hidden, 'count': keys.length};

    case 'launcher_apps_launch':
      final ref = requireString('app');
      final action = arguments['action'];
      if (action != null && (action is! String || action.isEmpty)) {
        throw const FormatException('action must be a non-empty string');
      }
      final apps = await ensureApps();
      final key = resolveAppRef(ref, apps);
      if (key == null) throw ServiceError('unknown_app', 'Unknown app: $ref');
      final result = action is String
          ? await core.routes['apps.action']!({'key': key, 'action': action})
          : await core.routes['apps.launch']!({'key': key});
      return {'key': key, ...result};

    case 'launcher_groups_list':
      final includeApps = arguments['include_apps'] == true;
      if (arguments.containsKey('include_apps') &&
          arguments['include_apps'] is! bool) {
        throw const FormatException('include_apps must be a boolean');
      }
      final apps = await ensureApps();
      final groupData = core.loadGroupsData();
      final byGroup = <String, List<Map<String, dynamic>>>{};
      for (final app in apps) {
        final gid = app['group'] as String? ?? groups.other;
        byGroup.putIfAbsent(gid, () => []).add({
          'key': app['key'],
          'desktop_id': app['desktop_id'],
          'name': app['name'],
        });
      }
      final collapsed = (groupData['collapsed'] as List).cast<String>().toSet();
      final list = <Map<String, dynamic>>[
        for (final g in groupData['groups'] as List)
          {
            'id': g['id'],
            'name': g['name'],
            'display_name': groups.displayName(g['id'] as String, groupData),
            'builtin': groups.builtinNames.containsKey(g['id']),
            'new': g['new'] == true,
            'collapsed': collapsed.contains(g['id']),
            'count': (byGroup[g['id']] ?? const []).length,
            if (includeApps) 'apps': byGroup[g['id']] ?? const [],
          },
        {
          'id': groups.other,
          'name': '',
          'display_name': 'Other',
          'builtin': true,
          'new': false,
          'collapsed': collapsed.contains(groups.other),
          'count': (byGroup[groups.other] ?? const []).length,
          if (includeApps) 'apps': byGroup[groups.other] ?? const [],
        },
      ];
      return {'groups': list};

    case 'launcher_groups_create':
      final groupName = requireString('name');
      final appRefs = arguments.containsKey('apps')
          ? requireStringList('apps', allowEmpty: true)
          : const <String>[];
      List<String> keys = const [];
      if (appRefs.isNotEmpty) {
        final apps = await ensureApps();
        keys = resolveApps(appRefs, apps);
      }
      final created = await core.routes['groups.add']!({'name': groupName});
      final newId = created['result'] as String;
      for (final key in keys) {
        await core.routes['groups.place']!({'key': key, 'group': newId});
      }
      final freshData = core.loadGroupsData();
      return {
        'id': newId,
        'name': groups.displayName(newId, freshData),
        'moved': keys,
        'groups': _groupsSummary(freshData),
      };

    case 'launcher_groups_rename':
      final groupRef = requireString('group');
      final newName = requireString('name');
      final groupData = core.loadGroupsData();
      final gid = resolveGroupRef(groupRef, groupData);
      if (gid == null) throw ServiceError('unknown_group', 'Unknown group: $groupRef');
      if (gid == groups.other) {
        throw ServiceError('refused', 'Cannot rename Other.');
      }
      await core.routes['groups.rename']!({'id': gid, 'name': newName});
      final freshData = core.loadGroupsData();
      return {
        'id': gid,
        'name': groups.displayName(gid, freshData),
        'groups': _groupsSummary(freshData),
      };

    case 'launcher_groups_delete':
      final groupRef = requireString('group');
      final groupData = core.loadGroupsData();
      final gid = resolveGroupRef(groupRef, groupData);
      if (gid == null) throw ServiceError('unknown_group', 'Unknown group: $groupRef');
      if (gid == groups.other) {
        throw ServiceError('refused', 'Cannot delete Other.');
      }
      final oldName = groups.displayName(gid, groupData);
      await core.routes['groups.delete']!({'id': gid});
      return {
        'deleted': gid,
        'name': oldName,
        'groups': _groupsSummary(core.loadGroupsData()),
      };

    case 'launcher_groups_move_apps':
      final appRefs = requireStringList('apps');
      final groupRef = requireString('group');
      final create = arguments['create'] == true;
      if (arguments.containsKey('create') && arguments['create'] is! bool) {
        throw const FormatException('create must be a boolean');
      }
      final apps = await ensureApps();
      final keys = resolveApps(appRefs, apps);
      final groupData = core.loadGroupsData();
      var gid = resolveGroupRef(groupRef, groupData);
      var createdGroup = false;
      if (gid == null) {
        if (!create) {
          throw ServiceError('unknown_group', 'Unknown group: $groupRef');
        }
        final added = await core.routes['groups.add']!({'name': groupRef});
        gid = added['result'] as String;
        createdGroup = true;
      }
      for (final key in keys) {
        await core.routes['groups.place']!({'key': key, 'group': gid});
      }
      final freshData = core.loadGroupsData();
      return {
        'group': gid,
        'group_name': groups.displayName(gid, freshData),
        'created': createdGroup,
        'moved': keys,
        'count': keys.length,
        'groups': _groupsSummary(freshData),
      };

    case 'launcher_groups_reorder':
      final groupRef = requireString('group');
      final targetRef = arguments['target'];
      final delta = arguments['delta'];
      final after = arguments['after'] == true;
      if (arguments.containsKey('after') && arguments['after'] is! bool) {
        throw const FormatException('after must be a boolean');
      }
      final groupData = core.loadGroupsData();
      final gid = resolveGroupRef(groupRef, groupData);
      if (gid == null) throw ServiceError('unknown_group', 'Unknown group: $groupRef');
      if (gid == groups.other) {
        throw ServiceError('refused', 'Cannot reorder Other.');
      }
      if (targetRef != null) {
        if (targetRef is! String || targetRef.trim().isEmpty) {
          throw const FormatException('target must be a non-empty string');
        }
        final targetId = resolveGroupRef(targetRef, groupData);
        if (targetId == null || targetId == groups.other) {
          throw ServiceError('unknown_group', 'Unknown target group: $targetRef');
        }
        await core.routes['groups.reorder']!({
          'id': gid,
          'target': targetId,
          'after': after,
        });
      } else if (delta == -1 || delta == 1) {
        await core.routes['groups.move']!({'id': gid, 'delta': delta});
      } else {
        throw const FormatException('Provide either target or delta (-1 or 1)');
      }
      return {'groups': _groupsSummary(core.loadGroupsData())};

    case 'launcher_groups_toggle':
      final groupRef = requireString('group');
      final groupData = core.loadGroupsData();
      final gid = resolveGroupRef(groupRef, groupData);
      if (gid == null) throw ServiceError('unknown_group', 'Unknown group: $groupRef');
      final res = await core.routes['groups.toggle']!({'id': gid});
      final collapsed = (res['collapsed'] as List).cast<String>();
      return {
        'group': gid,
        'collapsed': collapsed.contains(gid),
      };

    case 'launcher_dock_state':
      return await core.routes['dock.state']!(const {});

    case 'launcher_dock_pin':
      final refs = requireStringList('apps');
      final pinned = requireBool('pinned');
      final apps = await ensureApps();
      final keys = resolveApps(refs, apps);
      Map<String, dynamic> last = {'pinned': core.dock.pinned()};
      for (final key in keys) {
        last = await core.routes['dock.pin']!({'key': key, 'pinned': pinned});
      }
      return {'apps': keys, 'pinned_state': pinned, 'pinned': last['pinned']};

    case 'launcher_shortcuts_list':
      final apps = await ensureApps();
      final appRef = arguments['app'];
      if (appRef != null) {
        if (appRef is! String || appRef.trim().isEmpty) {
          throw const FormatException('app must be a non-empty string');
        }
        final key = resolveAppRef(appRef, apps);
        if (key == null) throw ServiceError('unknown_app', 'Unknown app: $appRef');
        return await core.routes['shortcuts.state']!({'key': key});
      }
      final labels = await core.routes['shortcuts.labels']!(const {});
      return labels;

    case 'launcher_settings_get':
      return await core.routes['settings.get']!(const {});

    case 'launcher_settings_set':
      final key = requireString('key');
      return await core.routes['settings.set']!({
        'key': key,
        'value': arguments['value'],
      });

    default:
      throw FormatException('Unknown tool: $name');
  }
}

List<Map<String, dynamic>> _groupsSummary(groups.GroupData data) => [
  for (final g in data['groups'] as List)
    {
      'id': g['id'],
      'name': g['name'],
      'display_name': groups.displayName(g['id'] as String, data),
      'builtin': groups.builtinNames.containsKey(g['id']),
      'new': g['new'] == true,
    },
  {'id': groups.other, 'name': '', 'display_name': 'Other', 'builtin': true, 'new': false},
];

/// Handle one JSON-RPC 2.0 frame for the Maprisma Launcher MCP server.
/// Returns null for valid JSON-RPC notifications (e.g. `notifications/initialized`).
Future<Map<String, Object?>?> launcherMcpReply(
  dynamic frame,
  CoreService core, {
  String serverName = 'Maprisma Launcher',
}) async {
  if (frame is! Map || frame['jsonrpc'] != '2.0') {
    return {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': -32600, 'message': 'Invalid request'},
    };
  }
  final method = frame['method'];
  if (method is! String || method.isEmpty) {
    return {
      'jsonrpc': '2.0',
      'id': _validId(frame['id']) ? frame['id'] : null,
      'error': {'code': -32600, 'message': 'Invalid request'},
    };
  }
  if (!frame.containsKey('id')) {
    // Valid JSON-RPC notification (such as notifications/initialized).
    return null;
  }
  final id = frame['id'];
  if (!_validId(id)) {
    return {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': -32600, 'message': 'Invalid request'},
    };
  }
  final reply = <String, Object?>{'jsonrpc': '2.0', 'id': id};
  final params = frame['params'];
  switch (method) {
    case 'initialize':
      reply['result'] = {
        'protocolVersion': '2024-11-05',
        'capabilities': {'tools': <String, Object?>{}},
        'serverInfo': {'name': serverName, 'version': coreVersion},
      };
    case 'ping':
      reply['result'] = <String, Object?>{};
    case 'tools/list':
      reply['result'] = {'tools': launcherMcpTools};
    case 'tools/call':
      if (params is! Map) {
        reply['error'] = {'code': -32602, 'message': 'Invalid tool call'};
        break;
      }
      final name = params['name'];
      final rawArgs = params['arguments'] ?? <String, dynamic>{};
      if (name is! String ||
          rawArgs is! Map ||
          rawArgs.keys.any((k) => k is! String)) {
        reply['error'] = {'code': -32602, 'message': 'Invalid tool call'};
        break;
      }
      if (!_allowedKeysByTool.containsKey(name)) {
        reply['error'] = {'code': -32602, 'message': 'Invalid tool call'};
        break;
      }
      final arguments = Map<String, dynamic>.from(rawArgs);
      try {
        final payload = await callLauncherMcpTool(core, name, arguments);
        reply['result'] = _toolText(payload);
      } on FormatException catch (error) {
        reply['result'] = _toolText({
          'code': 'invalid_request',
          if (error.message.isNotEmpty) 'message': error.message,
        }, error: true);
      } on ServiceError catch (error) {
        reply['result'] = _toolText({
          'code': error.code,
          if (error.reason != null && error.reason!.isNotEmpty)
            'message': error.reason,
        }, error: true);
      }
    default:
      reply['error'] = {'code': -32601, 'message': 'Method not found'};
  }
  return reply;
}

/// Serve the Maprisma Launcher MCP server on stdin/stdout until EOF or signal.
Future<int> runLauncherMcpStdio(
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final String? configDir;
  try {
    configDir = parseLauncherMcpArgs(args);
  } on FormatException {
    stderr.writeln(launcherMcpUsage);
    return 64;
  }
  final core = CoreService(
    environment: environment ?? Platform.environment,
    configDir: configDir,
  );
  var shuttingDown = false;
  void writeJson(Map<String, Object?> payload) {
    if (shuttingDown) return;
    try {
      stdout.writeln(jsonEncode(payload));
    } on Object {
      // Peer closed stdout.
    }
  }

  final signals = <StreamSubscription<ProcessSignal>>[];
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    try {
      signals.add(
        sig.watch().listen((_) {
          shuttingDown = true;
        }),
      );
    } on SignalException {
      // Unsupported on this platform.
    }
  }

  Future<void> handleLine(List<int> rawBytes, bool wasOversized) async {
    if (wasOversized) {
      writeJson({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32600, 'message': 'Request too large'},
      });
      return;
    }
    final String text;
    try {
      text = utf8.decode(rawBytes).trim();
    } on FormatException {
      writeJson({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      return;
    }
    if (text.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      writeJson({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      return;
    }
    if (decoded is Map &&
        decoded['jsonrpc'] == '2.0' &&
        !decoded.containsKey('id') &&
        decoded['method'] == 'notifications/initialized') {
      return;
    }
    final reqId = decoded is Map ? decoded['id'] : null;
    try {
      final response = await launcherMcpReply(decoded, core);
      if (response != null) writeJson(response);
    } on Object {
      writeJson({
        'jsonrpc': '2.0',
        'id': _validId(reqId) ? reqId : null,
        'error': {'code': -32603, 'message': 'Internal error'},
      });
    }
  }

  final frame = <int>[];
  var oversized = false;
  try {
    await for (final chunk in stdin) {
      if (shuttingDown) break;
      for (final byte in chunk) {
        if (byte == 10) {
          final copy = List<int>.of(frame);
          final wasOversized = oversized;
          frame.clear();
          oversized = false;
          await handleLine(copy, wasOversized);
        } else if (!oversized) {
          if (frame.length >= launcherMcpMaxLine) {
            frame.clear();
            oversized = true;
          } else {
            frame.add(byte);
          }
        }
      }
    }
    if (!shuttingDown && (oversized || frame.isNotEmpty)) {
      await handleLine(List<int>.of(frame), oversized);
    }
  } finally {
    shuttingDown = true;
    for (final sub in signals) {
      await sub.cancel();
    }
    core.dispose();
  }
  return 0;
}
