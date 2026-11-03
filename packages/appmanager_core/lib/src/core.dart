/// The core service: requests from the GUI (docs/protocol.md) answered from
/// the scan, the user's files and the desktop adapter. Runs in the GUI's
/// background isolate.
library;

import 'dart:convert';

import 'apps.dart';
import 'config.dart';
import 'desktop_entries.dart';
import 'desktops.dart';
import 'groups.dart' as groups;
import 'icon_theme.dart';
import 'launch.dart';
import 'protocol.dart';

const coreVersion = '0.2.0';

/// An entry's stable key: its desktop file, else its kind and id.
String appKey(Map app) {
  final path = app['desktop_path'] as String? ?? '';
  return path.isNotEmpty ? path : 'argv:${app['desktop_id']}';
}

final class CoreService {
  CoreService({
    Map<String, String>? environment,
    Session? session,
    String? configDir,
  }) : session = session ?? Session(environment: environment ?? const {}) {
    desktop = detectDesktop(this.session);
    store = ConfigStore(this.session, dir: configDir);
    settings = Settings(store);
  }

  final Session session;
  late final Desktop desktop;
  late final ConfigStore store;
  late final Settings settings;
  Map<String, dynamic> imported = const {};
  bool _started = false;
  IconTheme? _icons;
  String? _iconThemeName;
  final _apps = <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>> _list = [];

  late final Map<String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>
  routes = {
    'core.hello': (_) async => {
      'version': coreVersion,
      'protocol': protocolVersion,
      'desktop': desktop.name,
      'imported': imported,
    },
    'desktop.look': (_) => desktop.look(),
    'apps.list': (_) => _listApps(),
    'apps.launch': (params) => _launch(params, null),
    'apps.action': (params) => _launch(params, _string(params, 'action')),
    'apps.sections': _sections,
    'apps.hide': (params) async {
      final app = _app(params);
      final hidden = loadHidden(store);
      params['hidden'] == true
          ? hidden.add(app['desktop_id'] as String)
          : hidden.remove(app['desktop_id']);
      saveHidden(store, hidden);
      return {'hidden': hidden.contains(app['desktop_id'])};
    },
    'groups.get': (_) async => _groupsView(_loadGroups()),
    'groups.place': (params) => _editGroups((data) {
      final app = _app(params);
      final gid = _string(params, 'group');
      final target = params['target'];
      final targetApp = target is String ? _apps[target] : null;
      final targetId = targetApp?['desktop_id'] as String?;
      groups.place(
        data,
        app['desktop_id'] as String,
        gid,
        targetId,
        _memberIds(data, gid),
        after: params['after'] == true,
      );
    }),
    'groups.add': (params) => _editGroups((data) {
      final gid = groups.addGroup(data, _string(params, 'name'));
      final key = params['key'];
      if (key is String && _apps[key] != null) {
        groups.place(data, _apps[key]!['desktop_id'] as String, gid, null, _memberIds(data, gid));
      }
      return gid;
    }),
    'groups.rename': (params) => _editGroups(
      (data) => groups.renameGroup(data, _string(params, 'id'), _string(params, 'name')),
    ),
    'groups.delete': (params) => _editGroups((data) => groups.deleteGroup(data, _string(params, 'id'))),
    'groups.move': (params) => _editGroups((data) {
      final delta = params['delta'];
      if (delta != 1 && delta != -1) throw ServiceError('bad_params');
      groups.moveGroup(data, _string(params, 'id'), delta as int);
    }),
    'groups.reorder': (params) => _editGroups(
      (data) => groups.reorderGroup(
        data,
        _string(params, 'id'),
        _string(params, 'target'),
        after: params['after'] == true,
      ),
    ),
    'groups.toggle': (params) => _editGroups((data) {
      final gid = _string(params, 'id');
      final foldable = {...groups.groupIds(data), groups.other, groups.running, ...desktop.origins};
      if (!foldable.contains(gid)) throw ServiceError('bad_params');
      groups.toggleCollapsed(data, gid);
    }),
    'settings.get': (_) async => settings.read(),
    'settings.reset': (_) async {
      settings.reset();
      return settings.read();
    },
    'settings.set': (params) async {
      try {
        settings.set(_string(params, 'key'), params['value']);
      } on ArgumentError {
        throw ServiceError('bad_params');
      }
      return settings.read();
    },
  };

  void _start() {
    if (_started) return;
    _started = true;
    try {
      imported = store.importOldConfig();
    } on Object {
      imported = {'error': true};
    }
  }

  static String _string(Map<String, dynamic> params, String key) {
    final value = params[key];
    if (value is! String || value.isEmpty || value.length > 4096) {
      throw ServiceError('bad_params');
    }
    return value;
  }

  Map<String, dynamic> _app(Map<String, dynamic> params) {
    final key = params['key'];
    final app = key is String ? _apps[key] : null;
    if (app == null) throw ServiceError('unknown_app');
    return app;
  }

  groups.GroupData _loadGroups() {
    final data = store.readJson('groups.json');
    return groups.cleanPage(data is Map ? data['apps'] : null, desktop.origins);
  }

  void _saveGroups(groups.GroupData page) {
    final data = store.readJson('groups.json');
    store.writeJson('groups.json', {...(data is Map ? data : const {}), 'apps': page});
  }

  Map<String, dynamic> _groupsView(groups.GroupData data) => {
    'groups': [
      for (final g in data['groups'] as List)
        {
          'id': g['id'],
          'name': g['name'],
          'builtin': groups.builtinNames.containsKey(g['id']),
          'new': g['new'] == true,
        },
    ],
    'collapsed': data['collapsed'],
    'origins': desktop.origins,
  };

  /// group_member_ids: the ids of a group's entries in the order they show.
  List<String> _memberIds(groups.GroupData data, String gid) {
    // All entries, hidden ones too: their places stay when they come back.
    final section = groups.sections(_list, data).where((s) => s.$1 == gid).firstOrNull;
    return [for (final a in section?.$2 ?? const <Map>[]) a['desktop_id'] as String];
  }

  Future<Map<String, dynamic>> _editGroups(dynamic Function(groups.GroupData) edit) async {
    final data = _loadGroups();
    Object? result;
    try {
      result = edit(data);
    } on groups.GroupError catch (e) {
      throw ServiceError('refused', e.message);
    }
    _saveGroups(data);
    return {..._groupsView(data), 'result': ?result};
  }

  Future<IconTheme> _iconTheme() async {
    final name = await desktop.iconTheme();
    if (_icons == null || name != _iconThemeName) {
      _icons = IconTheme(session, name);
      _iconThemeName = name;
    }
    return _icons!;
  }

  Future<Map<String, dynamic>> _listApps() async {
    _start();
    final apps = await scanApps(session);
    final icons = await _iconTheme();
    final hidden = loadHidden(store);
    final defaults = desktop.defaultDesktops();
    final data = _loadGroups();
    _apps.clear();
    _list = apps;
    final out = <Map<String, dynamic>>[];
    for (final app in apps) {
      final key = appKey(app);
      _apps[key] = app;
      out.add({
        ...app,
        'key': key,
        'icon_file':
            icons.lookup(app['icon'] as String? ?? '') ?? icons.lookup('application-x-executable'),
        'hidden': hidden.contains(app['desktop_id']),
        'group': groups.groupOf(app, data),
        'origin': desktop.origin(app, defaults),
        'roles': desktop.defaultRoles(app),
      });
    }
    return {'apps': out, 'icon_theme': _iconThemeName, ..._groupsView(data)};
  }

  /// The sections of the groups or origin view for the entries shown (in
  /// list order, given by key): [{id, keys}], empty ones included.
  Future<Map<String, dynamic>> _sections(Map<String, dynamic> params) async {
    final view = params['view'];
    final keys = params['keys'];
    if ((view != 'groups' && view != 'origin') || keys is! List) {
      throw ServiceError('bad_params');
    }
    final entries = [
      for (final k in keys)
        if (k is String && _apps[k] != null) _apps[k]!,
    ];
    final data = _loadGroups();
    final defaults = desktop.defaultDesktops();
    final sections = view == 'groups'
        ? groups.sections(entries, data)
        : groups.originSections(
            entries,
            desktop.origins,
            (app) => desktop.origin(app, defaults),
          );
    return {
      'sections': [
        for (final (id, members) in sections)
          {
            'id': id,
            'keys': [for (final a in members) appKey(a)],
          },
      ],
      ..._groupsView(data),
    };
  }

  Future<Map<String, dynamic>> _launch(Map<String, dynamic> params, String? action) async {
    final app = _app(params);
    final ok = action == null
        ? await desktop.launch(app)
        : await launchApp(app, session, terminal: desktop.terminal(), action: action);
    if (!ok) throw ServiceError('launch_failed');
    return {'started': true};
  }

  Future<String> handleAsync(String frame) async {
    int? id;
    try {
      final request = Request.decode(frame);
      id = request.id;
      final route = routes[request.method];
      if (route == null) throw ServiceError('unknown_route');
      final result = await route(request.params);
      return jsonEncode({'id': id, 'result': result});
    } on ServiceError catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': e.code, 'message': ?e.reason},
      });
    } on FormatException {
      return jsonEncode({
        'id': id,
        'error': {'code': 'bad_request'},
      });
    } catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': 'internal'},
      });
    }
  }

  void dispose() {}
}
