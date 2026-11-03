/// The core service: requests from the GUI (docs/protocol.md) answered from
/// the scan, the user's files and the desktop adapter. Runs in the GUI's
/// background isolate.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'apps.dart';
import 'ask_ai.dart';
import 'bounded.dart';
import 'config.dart';
import 'desktop_entries.dart';
import 'desktops.dart';
import 'facts.dart';
import 'groups.dart' as groups;
import 'icon_theme.dart';
import 'launch.dart';
import 'newapps.dart';
import 'origins.dart' show defaultRoles;
import 'packages.dart';
import 'running.dart';
import 'updates.dart';
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
  Set<String> _running = {};
  late final _facts = AppFacts(session);
  late final _managers = Managers(session);

  /// The last search's results: only these can be installed.
  List<Found> _found = [];
  late final _ask = AskRunner(session);
  Map<String, dynamic> _updates = {'apps': {}, 'flatpaks': {}};
  DateTime? _updatesAt;
  Future<Map<String, dynamic>>? _checking;

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
    // Package facts for cards and Details: one pacman call, the database
    // read directly, one flatpak list; cached until a database changes.
    'apps.facts': (_) async => {'facts': await _facts.all(_apps)},
    'apps.running': (_) async {
      final (names, exes) = processNames();
      _running = runningApps(_apps, names, exes);
      return {'running': _running.toList()};
    },
    'updates.check': (params) => _checkUpdates(force: params['force'] == true),
    'updates.flatpak': (params) async {
      final plan = uninstallPlan(_app(params), session);
      if (plan == null || plan.$1 != 'flatpak') throw ServiceError('bad_params');
      final (ok, message) = await UpdateCheck(session).runFlatpakUpdate(plan.$2!);
      if (!ok) throw ServiceError('update_failed', message);
      (_updates['flatpaks'] as Map).remove(plan.$2);
      return _updatesView();
    },
    'updates.system': (_) async {
      final command = desktop.systemUpdate();
      if (command == null || !await startDetached(command, session)) throw ServiceError('no_updater');
      _updatesAt = null; // Check again the next time.
      return {'started': true};
    },
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
    'ask.helpers': (_) async => {'helpers': helperStates(session), 'chosen': settings.raw()['ask_helper']},
    'ask.run': _askRun,
    'ask.cancel': (_) async {
      _ask.cancel();
      return {'cancelled': true};
    },
    'ask.signin': (params) async {
      final helper = helpers.where((h) => h.command == params['command']).firstOrNull;
      final terminal = desktop.terminal();
      if (helper == null || terminal == null) throw ServiceError('bad_params');
      // The helper's own sign-in, from the table: no text of the user in it.
      if (!await startDetached([...terminal, 'sh', '-c', helper.login], session)) throw ServiceError('no_terminal');
      return {'started': true};
    },
    // A website from Details: only http(s), no control characters, the
    // desktop's opener, never a shell.
    'open.url': (params) async {
      final url = _string(params, 'url');
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty ||
          url.length > 2000 || url.contains(RegExp(r'[\x00-\x20\x7f]'))) {
        throw ServiceError('bad_params');
      }
      final opener = session.which('xdg-open');
      if (opener == null || !await startDetached([opener, url], session)) throw ServiceError('no_opener');
      return {'started': true};
    },
    'packages.managers': (_) async => _managersView(),
    'packages.search': (params) async {
      final query = _string(params, 'query').trim();
      if (query.isEmpty || query.length > 100 || query.contains(RegExp(r'[\x00-\x1f]'))) {
        throw ServiceError('bad_params');
      }
      _found = await _managers.search(query, _enabledManagers());
      return {'results': _found};
    },
    'packages.install_plan': (params) async => _installPlan(params),
    'packages.install': (params) async {
      final plan = await _installPlan(params);
      final command = plan['argv'] as List<String>;
      if (!await startDetached(command, session)) throw ServiceError('no_terminal');
      return {'started': true};
    },
    'apps.uninstall_plan': (params) async => _uninstallPlan(_app(params)),
    'apps.uninstall': (params) => _uninstall(_app(params)),
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
    final seen = cleanSeen(store.readJson('seen.json', cap: 512 * 1024));
    final installed = {
      for (final a in apps)
        if (a['installed_at'] case final num at) a['desktop_id'] as String: at,
    };
    if (noteSeen(seen, [for (final a in apps) a['desktop_id'] as String], 'apps', installed: installed)) {
      _saveSeen(seen);
    }
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
        'new': isNewApp(seen, app['desktop_id'] as String),
        'uninstall': uninstallPlan(app, session)?.$1,
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
    final running = params['running'] == true ? (Map app) => _running.contains(appKey(app)) : null;
    final sections = view == 'groups'
        ? groups.sections(entries, data, isRunning: running)
        : groups.originSections(entries, desktop.origins, (app) => desktop.origin(app, defaults), isRunning: running);
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

  /// Ask AI: one click, at most two answers, never a retry. The helper only
  /// sees facts; every name it returns is checked here.
  Future<Map<String, dynamic>> _askRun(Map<String, dynamic> params) async {
    final request = _string(params, 'request').trim();
    if (request.length > 2000) throw ServiceError('bad_params');
    final command = _string(params, 'helper');
    final state = helperStates(session).where((h) => h['command'] == command).firstOrNull;
    if (state == null || state['installed'] != true) throw ServiceError('no_helper');
    final answer = params['answer'] is String ? (params['answer'] as String) : null;
    final language = params['language'] is String ? params['language'] as String : null;
    settings.store.writeJson('settings.json', {...settings.raw(), 'ask_helper': command});
    if (_apps.isEmpty) await _listApps();
    // Short ids keep the prompt small; they map back to the keys here.
    final keys = _apps.keys.toList();
    final ids = {for (var i = 0; i < keys.length; i++) 'a$i': keys[i]};
    final hidden = loadHidden(store);
    final defaults = desktop.defaultDesktops();
    List<Map> facts(Iterable<String> only) => [
      for (final e in ids.entries)
        if (only.isEmpty || only.contains(e.key))
          if (_apps[e.value] case final app? when !hidden.contains(app['desktop_id']))
            {
              'id': e.key,
              'name': app['name'],
              'description': '${app['description'] ?? ''}'.length > 80
                  ? '${app['description']}'.substring(0, 80)
                  : app['description'],
              'origin': desktop.origin(app, defaults),
              if ((_updates['apps'] as Map).containsKey(app['desktop_path'])) 'update': true,
              if (uninstallPlan(app, session) case (final kind, _) when kind != 'webapp') 'removable': true,
            },
    ];
    final managers = _enabledManagers();
    String text;
    try {
      text = await _ask.run(
        command,
        askPrompt(request: request, answer: answer, installed: facts(const []), managers: managers, language: language),
      );
    } on Object catch (e) {
      throw ServiceError('helper_failed', '$e');
    }
    final first = checkAsk(firstJson(text), ids.keys.toSet());
    List<String> toKeys(Object? list) => [for (final id in (list as List? ?? const [])) ?ids[id]];
    switch (first['action']) {
      case 'search':
        final merged = <Found>[];
        for (final q in first['queries'] as List) {
          for (final f in await _managers.search(q as String, managers)) {
            if (!merged.any((m) => m['manager'] == f['manager'] && m['package'] == f['package'])) merged.add(f);
          }
        }
        // Official repositories first, the AUR last (Antigravity's review, 6b).
        merged.sort((a, b) => (a['aur'] == true ? 1 : 0).compareTo(b['aur'] == true ? 1 : 0));
        final found = merged.take(maxSearchResults).toList();
        _found = found;
        final already = first['installed'] as List;
        if (found.isEmpty) {
          return {'action': 'install', 'summary': '', 'picks': [], 'installed': toKeys(already), 'queries': first['queries']};
        }
        String second;
        try {
          second = await _ask.run(
            command,
            picksPrompt(
              request: request,
              answer: answer,
              found: [
                for (final f in found)
                  {
                    'manager': f['manager'],
                    'package': f['package'],
                    'version': f['version'],
                    'description': '${f['description'] ?? ''}'.length > 120
                        ? '${f['description']}'.substring(0, 120)
                        : f['description'],
                    if (f['aur'] == true) 'aur': true,
                    if (f['installed'] == true) 'installed': true,
                  },
              ],
              installed: facts(already.cast<String>()),
              language: language,
            ),
          );
        } on Object catch (e) {
          throw ServiceError('helper_failed', '$e');
        }
        final picks = checkPicks(firstJson(second), found, ids.keys.toSet());
        return {
          'action': 'install',
          'summary': picks['summary'],
          'picks': picks['picks'],
          'installed': toKeys({...already, ...picks['installed'] as List}.toList()),
          'queries': first['queries'],
        };
      case 'remove' || 'update' || 'explain':
        return {...first, 'apps': toKeys(first['apps'])};
      default:
        return first;
    }
  }

  List<String> _enabledManagers() =>
      (settings.read()['package_managers'] as List?)?.cast<String>() ?? _managers.defaults();

  Map<String, dynamic> _managersView() {
    final there = _managers.installed();
    final enabled = _enabledManagers();
    return {
      'managers': [
        for (final (id, label, _) in managerKinds)
          if (there[id] case final program?)
            {'id': id, 'label': label, 'program': p.basename(program), 'enabled': enabled.contains(id)},
      ],
    };
  }

  /// What an install will run: only a package the last search found, of an
  /// enabled manager; the exact command line is shown before it runs.
  Future<Map<String, dynamic>> _installPlan(Map<String, dynamic> params) async {
    final manager = _string(params, 'manager'), package = _string(params, 'package');
    final found = _found.where((f) => f['manager'] == manager && f['package'] == package).firstOrNull;
    if (found == null || !_enabledManagers().contains(manager)) throw ServiceError('not_found');
    final terminal = desktop.terminal();
    final argv = terminal == null ? null : _managers.installCommand(manager, found, terminal);
    if (argv == null) throw ServiceError('no_terminal');
    return {
      'manager': manager,
      'package': package,
      'argv': argv,
      // Shown to the user: the line the terminal runs, with the package in it.
      'command': _shownCommand(argv),
      'aur': manager == 'aur',
    };
  }

  static String _shownCommand(List<String> argv) {
    final i = argv.indexOf('-c');
    if (i < 0 || i + 1 >= argv.length) return argv.join(' ');
    var line = argv[i + 1].split(';').first;
    final args = argv.sublist(i + 3);
    for (var n = 0; n < args.length; n++) {
      line = line.replaceAll('"\$${n + 1}"', args[n]);
    }
    return line;
  }

  /// details.uninstall_plan, extended: the owning package of any system
  /// manager (pacman, apt, dnf, zypper), Snap apps, and warnings for default
  /// apps and Omarchy's own packages.
  Future<Map<String, dynamic>> _uninstallPlan(Map app) async {
    final plan = uninstallPlan(app, session);
    final desktopPath = app['desktop_path'] as String? ?? '';
    final roles = defaultRoles(app, session);
    final warnings = [if (roles.isNotEmpty) 'default'];
    if (plan == null) return {'kind': null};
    if (plan.$1 == 'package') {
      if (app['sandboxed'] == true && desktopPath.contains('/snapd/')) {
        final name = p.basename(desktopPath).split('_').first;
        return {'kind': 'package', 'manager': 'snap', 'what': name, 'warnings': warnings};
      }
      final owner = await _managers.ownerOf(desktopPath);
      if (owner == null) return {'kind': null};
      if (desktop is OmarchyDesktop && (desktop as OmarchyDesktop).basePackages.contains(owner.$2)) {
        warnings.add('omarchy');
      }
      return {'kind': 'package', 'manager': owner.$1, 'what': owner.$2, 'warnings': warnings};
    }
    return {'kind': plan.$1, 'what': plan.$2, 'warnings': warnings};
  }

  Future<Map<String, dynamic>> _uninstall(Map app) async {
    final plan = await _uninstallPlan(app);
    final what = plan['what'] as String?;
    switch (plan['kind']) {
      case 'trash':
        final moved = what == null ? null : moveToTrash(what, session);
        if (moved == null) throw ServiceError('uninstall_failed');
        return {'done': true, 'trash': moved};
      case 'flatpak':
        final flatpak = session.which('flatpak');
        final out = flatpak == null
            ? null
            : await readBoundedText(
                [flatpak, 'uninstall', '-y', '--noninteractive', what!],
                maxBytes: 64 * 1024,
                timeout: const Duration(seconds: 300),
              );
        if (out == null) throw ServiceError('uninstall_failed');
        return {'done': true};
      case 'package':
        final terminal = desktop.terminal();
        final argv = terminal == null ? null : _managers.removeCommand(plan['manager'] as String, what!, terminal);
        if (argv == null || !await startDetached(argv, session)) throw ServiceError('no_terminal');
        return {'started': true};
      default:
        throw ServiceError('cannot_uninstall');
    }
  }

  void _saveSeen(SeenData seen) {
    try {
      store.writeJson('seen.json', seen);
    } on FileSystemException {
      // The marks are a convenience: a read-only config only loses them.
    }
  }

  Map<String, dynamic> _updatesView() => {
    'apps': _updates['apps'],
    'flatpaks': {
      for (final e in _apps.entries)
        if (uninstallPlan(e.value, session) case ('flatpak', final id?))
          if ((_updates['flatpaks'] as Map)[id] case final List v) e.key: v,
    },
    'checked': _updatesAt?.toIso8601String(),
  };

  /// updates.check, at most every 30 minutes unless forced; one at a time.
  Future<Map<String, dynamic>> _checkUpdates({bool force = false}) {
    final fresh = _updatesAt != null && DateTime.now().difference(_updatesAt!) < const Duration(minutes: 30);
    if (fresh && !force) return Future.value(_updatesView());
    return _checking ??= () async {
      try {
        _updates = await UpdateCheck(session).check([for (final a in _list) a['desktop_path'] as String? ?? '']);
        _updatesAt = DateTime.now();
        return _updatesView();
      } finally {
        _checking = null;
      }
    }();
  }

  Future<Map<String, dynamic>> _launch(Map<String, dynamic> params, String? action) async {
    final app = _app(params);
    final seen = cleanSeen(store.readJson('seen.json', cap: 512 * 1024));
    if (openedApp(seen, app['desktop_id'] as String)) _saveSeen(seen); // Opened once: no longer new.
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
