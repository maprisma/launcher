/// The core service: requests from the GUI (docs/protocol.md) answered from
/// the scan, the user's files and the desktop adapter. Runs in the GUI's
/// background isolate.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'admin.dart';
import 'apps.dart';
import 'ask_ai.dart';
import 'bounded.dart';
import 'config.dart';
import 'desktop_entries.dart';
import 'desktops.dart';
import 'dock.dart';
import 'facts.dart';
import 'groups.dart' as groups;
import 'icon_theme.dart';
import 'icons.dart';
import 'hyprland.dart';
import 'plugins.dart';
import 'launch.dart';
import 'newapps.dart';
import 'origins.dart' show defaultRoles;
import 'packages.dart';
import 'running.dart';
import 'shortcut_service.dart';
import 'pty.dart';
import 'tray.dart';
import 'updates.dart';
import 'protocol.dart';
import 'shortcuts.dart' show defaultMods;

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
    String? executable,
  }) : session = session ?? Session(environment: environment ?? const {}),
       executable = executable ?? Platform.resolvedExecutable {
    desktop = detectDesktop(this.session);
    store = ConfigStore(this.session, dir: configDir);
    settings = Settings(store);
  }

  final Session session;

  /// This program (the dock and the window are both `maprisma-launcher`).
  final String executable;
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

  /// Global shortcuts: the desktop's backend (none on generic desktops).
  late final shortcuts = ShortcutService(backendFor(desktop, store), store);
  late final _managers = Managers(session);

  /// The last search's results: only these can be installed.
  List<Found> _found = [];
  late final _ask = AskRunner(session);
  late final _iconChoices = IconChoices(session, store);
  late final _hyprland = Hyprland(session);
  late final _plugins = ShellPlugins(session);
  late final _admin = Admin(session);
  late final _tray = Tray(session);

  /// The app's terminals (install, uninstall, system update), by id.
  final _terms = <String, PtySession>{};
  int _termCount = 0;

  /// The dock's settings and pinned apps (settings.json, keys dock_*).
  late final dock = DockStore(store);

  /// The last full list (apps.list's entries): what the dock shows.
  List<Map<String, dynamic>> _listed = const [];

  /// The last plugin list: only these ids are opened, moved, updated, removed.
  Map<String, Map<String, dynamic>> _pluginList = {};
  Map<String, int> _pluginUpdates = {};
  DateTime? _pluginUpdatesAt;

  /// The last window list (Hyprland): only these addresses can be focused.
  List<Map> _clients = const [];

  /// Change icon: the last search's online candidates, by url (only these
  /// can be previewed or chosen).
  final _iconCandidates = <String, Candidate>{};
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
      // Omarchy knows the windows: "active" (open windows) or "background".
      if (desktop is OmarchyDesktop && _hyprland.available) {
        _clients = await _hyprland.clients();
        final states = _hyprland.states(_apps, _clients, names, exes);
        _running = states.keys.toSet();
        return {'running': _running.toList(), 'states': states};
      }
      _running = runningApps(_apps, names, exes);
      return {'running': _running.toList()};
    },
    'apps.windows': (params) async {
      final app = _app(params);
      if (!_hyprland.available) return {'windows': const []};
      _clients = await _hyprland.clients();
      return {'windows': _hyprland.windowsOf(app, _clients)};
    },
    // Close: Hyprland asks each of the app's windows to close (as its ✕);
    // the app may still ask to save. Only windows Hyprland lists now.
    'apps.close': (params) async {
      final app = _app(params);
      if (!_hyprland.available) throw ServiceError('not_available');
      _clients = await _hyprland.clients();
      var closed = 0;
      for (final w in _hyprland.windowsOf(app, _clients)) {
        if (Hyprland.validAddress(w['address']) && await _hyprland.closeWindow(w['address'] as String)) closed++;
      }
      return {'closed': closed};
    },
    'window.focus': (params) async {
      final address = _string(params, 'address');
      // Only a window Hyprland listed just now.
      if (!_clients.any((c) => c['address'] == address)) throw ServiceError('not_found');
      if (!await _hyprland.focus(address)) throw ServiceError('focus_failed');
      return {'focused': true};
    },
    'apps.open_floating': (params) async {
      if (!await _hyprland.execFloating(_startArgv(_app(params)))) throw ServiceError('launch_failed');
      return {'started': true};
    },
    'apps.open_on_workspace': (params) async {
      final workspace = params['workspace'];
      if (workspace is! int) throw ServiceError('bad_params');
      if (!await _hyprland.execOnWorkspace(_startArgv(_app(params)), workspace)) throw ServiceError('launch_failed');
      return {'started': true};
    },
    'workspaces.list': (_) async => await _hyprland.workspaces() ?? {'workspaces': const [], 'free': null},
    // Open as administrator: off by default; on only after polkit confirmed
    // the password, for this login session only.
    'admin.state': (_) async => {
      'enabled': _admin.enabled(),
      'available': session.which('pkexec') != null && _admin.sessionDir() != null && _admin.sessionToken() != null,
    },
    'admin.enable': (params) async {
      if (params['on'] != true) {
        _admin.setEnabled(false);
        return {'enabled': false};
      }
      if (!await _admin.confirmPassword()) throw ServiceError('not_confirmed');
      try {
        _admin.setEnabled(true);
      } on FileSystemException {
        throw ServiceError('no_session');
      }
      return {'enabled': true};
    },
    'apps.admin_check': (params) async => {'can': _admin.enabled() && await _admin.command(_app(params)) != null},
    // The app's own tray Quit (never a signal from us): its label, or null.
    // The app's own terminal: only commands the core builds itself (a
    // package the last search found, an app's uninstall plan, the system
    // update); the page shows the output and passes the keys on.
    'term.start': (params) async {
      final (argv, command) = await _termCommand(params);
      // Ended terminals nobody closed (the page went away): let them go.
      for (final id in [for (final e in _terms.entries) if (e.value.ended) e.key]) {
        _terms.remove(id)?.close();
      }
      _updatesAt = null; // An install or update changes what is out of date.
      if (_terms.values.where((t) => !t.ended).length >= 4) throw ServiceError('busy');
      final cols = params['cols'], rows = params['rows'];
      final id = 't${++_termCount}';
      final pty = await PtySession.start(id, argv, session,
          title: '${params['action']}', command: command,
          cols: cols is int ? cols : 100, rows: rows is int ? rows : 30);
      if (pty == null) throw ServiceError('no_pty');
      _terms[id] = pty;
      return {'id': id, 'command': command};
    },
    'term.read': (params) async {
      final pty = _term(params);
      return {'data': base64Encode(pty.take()), 'ended': pty.ended, 'code': pty.exitCode};
    },
    'term.write': (params) async {
      final pty = _term(params);
      final data = params['data'];
      if (data is! String || data.length > 64 * 1024) throw ServiceError('bad_params');
      List<int> bytes;
      try {
        bytes = base64Decode(data);
      } on FormatException {
        throw ServiceError('bad_params');
      }
      return {'accepted': pty.write(bytes), 'ended': pty.ended};
    },
    'term.resize': (params) async {
      final cols = params['cols'], rows = params['rows'];
      if (cols is! int || rows is! int) throw ServiceError('bad_params');
      _term(params).resize(cols, rows);
      return {'resized': true};
    },
    'term.close': (params) async {
      final pty = _terms.remove('${params['id']}');
      pty?.close();
      return {'closed': pty != null};
    },
    'apps.quit_check': (params) async {
      final found = await _tray.quitFor(_app(params));
      return {'label': found?.$2['label']};
    },
    'apps.quit': (params) async {
      // Looked up again: tray menus and their ids change at any time.
      final found = await _tray.quitFor(_app(params));
      if (found == null) throw ServiceError('no_quit');
      if (!await _tray.click(found.$1, found.$2['id'] as int)) throw ServiceError('quit_failed');
      return {'clicked': true};
    },
    'apps.admin_launch': (params) async {
      if (!_admin.enabled()) throw ServiceError('not_enabled');
      if (!await _admin.launch(_app(params))) throw ServiceError('launch_failed');
      return {'started': true};
    },
    'plugins.list': (_) async {
      final list = await _plugins.list();
      _pluginList = {for (final pl in list) pl['plugin_id'] as String: pl};
      return {'plugins': [for (final pl in list) {...pl, 'behind': ?_pluginUpdates[pl['plugin_id']]}]};
    },
    'plugins.open': (params) async {
      if (!await _plugins.open(_plugin(params)['plugin_id'] as String)) throw ServiceError('open_failed');
      return {'opened': true};
    },
    'plugins.bar': (params) async {
      final plugin = _plugin(params);
      final section = params['section'];
      if (section != null && !barSections.contains(section)) throw ServiceError('bad_params');
      if (!await _plugins.setInBar(plugin['plugin_id'] as String, params['placed'] == true, section as String?)) {
        throw ServiceError('bar_failed');
      }
      return {'done': true};
    },
    'plugins.remove_plan': (params) async => _plugins.removalNote(_plugin(params)['plugin_id'] as String),
    'plugins.remove': (params) async {
      final plugin = _plugin(params);
      if (plugin['removable'] != true || !await _plugins.remove(plugin['plugin_id'] as String)) {
        throw ServiceError('remove_failed');
      }
      return {'removed': true};
    },
    // updates.plugin_updates: the user's git checkouts behind origin's
    // default branch, at most every 30 minutes unless forced.
    'plugins.updates': (params) async {
      final fresh = _pluginUpdatesAt != null && DateTime.now().difference(_pluginUpdatesAt!) < const Duration(minutes: 30);
      if (!fresh || params['force'] == true) {
        final ids = _pluginList.keys.where((id) => Directory(p.join(_plugins.userDir, id, '.git')).existsSync()).take(200);
        final counts = await Future.wait([for (final id in ids) _plugins.behind(id)]);
        _pluginUpdates = {
          for (final (i, id) in ids.indexed)
            if ((counts[i] ?? 0) > 0) id: counts[i]!,
        };
        _pluginUpdatesAt = DateTime.now();
      }
      return {'behind': _pluginUpdates};
    },
    'plugins.update': (params) async {
      final id = _plugin(params)['plugin_id'] as String;
      final (ok, message) = await _plugins.update(id);
      if (!ok) throw ServiceError('update_failed', message);
      _pluginUpdates.remove(id);
      return {'updated': true};
    },
    'window.popup': (params) async {
      final width = params['width'], height = params['height'];
      if (width is! int || height is! int) throw ServiceError('bad_params');
      if (!(desktop is OmarchyDesktop && _hyprland.available)) return {'placed': false, 'reason': 'not Omarchy'};
      return _hyprland.placePopup(pid, width, height);
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
    'icons.search': (params) async {
      final app = _app(params);
      final query = '${params['query'] ?? ''}'.trim();
      if (query.isEmpty || query.length > 100) throw ServiceError('bad_params');
      final icons = await _iconTheme();
      final q = fold(query).replaceAll(' ', '');
      final theme = (icons.names().where((n) => fold(n).replaceAll(' ', '').contains(q)).toList()..sort())
          .take(maxThemeResults)
          .map((n) => {'name': n, 'file': icons.lookup(n)})
          .where((t) => t['file'] != null)
          .toList();
      final online = await _iconChoices.online(query, app['cli_command'] as String?);
      _iconCandidates
        ..clear()
        ..addEntries(online.map((c) => MapEntry(c.$3, c)));
      return {
        'theme': theme,
        'online': [for (final c in online) {'collection': collectionNames[c.$1], 'slug': c.$2, 'url': c.$3}],
      };
    },
    'icons.preview': (params) async {
      final candidate = _iconCandidates[params['url']];
      if (candidate == null) throw ServiceError('not_found');
      return {'file': await _iconChoices.preview(candidate, _color(params))};
    },
    'icons.set': (params) async {
      final app = _app(params);
      final id = app['desktop_id'] as String;
      final overrides = _iconChoices.load();
      if (params['name'] case final String name) {
        final icons = await _iconTheme();
        if (!icons.names().contains(name) || !_iconChoices.validValue(name)) throw ServiceError('not_found');
        overrides[id] = name;
      } else {
        final candidate = _iconCandidates[params['url']];
        if (candidate == null) throw ServiceError('not_found');
        final got = await _iconChoices.download(candidate, _color(params));
        if (got == null) throw ServiceError('download_failed');
        overrides[id] = _iconChoices.storeFile(id, got.$1, got.$2);
      }
      _iconChoices.save(overrides);
      return {'set': true};
    },
    'icons.reset': (params) async {
      final app = _app(params);
      final overrides = _iconChoices.load()..remove(app['desktop_id']);
      _iconChoices.save(overrides);
      return {'reset': true};
    },
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
      if (desktop.terminal() == null) throw ServiceError('no_terminal');
      if (!await startDetached(command, session)) throw ServiceError('no_terminal');
      return {'started': true};
    },
    'apps.uninstall_plan': (params) async => _uninstallPlan(_app(params)),
    'apps.uninstall': (params) => _uninstall(_app(params)),
    'shortcuts.state': (params) async => shortcuts.view(_app(params), params),
    'shortcuts.set': (params) async => shortcuts.assign(_app(params), params),
    'shortcuts.remove': (params) async => shortcuts.remove(_app(params), params),
    'shortcuts.disable': (params) async => shortcuts.disable(_app(params), params),
    'shortcuts.restore': (params) async => shortcuts.restore(_app(params), params),
    'shortcuts.labels': (_) => shortcuts.labels(),
    'shortcuts.default_mods': (params) async {
      final mods = ShortcutService.mods(params['mods']);
      shortcuts.saveDefaultMods(mods.isEmpty ? defaultMods : mods);
      return {'default_mods': shortcuts.defaultMods()};
    },
    // The dock (Omarchy only): settings, pinned apps, what it shows.
    'dock.state': (_) => _dockState(),
    'dock.set': (params) async {
      try {
        dock.set(_string(params, 'key'), params['value']);
      } on ArgumentError {
        throw ServiceError('bad_params');
      }
      return _dockState();
    },
    'dock.reset': (_) async {
      dock.reset();
      return _dockState();
    },
    'dock.pin': (params) async {
      final id = _app(params)['desktop_id'] as String;
      params['pinned'] == false ? dock.unpin(id) : dock.pin(id);
      return {'pinned': dock.pinned()};
    },
    'dock.move': (params) async {
      final id = _string(params, 'id'), target = _string(params, 'target');
      final ids = dock.pinned();
      if (!ids.contains(id) || !ids.contains(target)) throw ServiceError('not_found');
      dock.setPinned(movePinned(ids, id, target, after: params['after'] == true));
      return {'pinned': dock.pinned()};
    },
    'dock.items': (params) async {
      if (params['rescan'] == true || _listed.isEmpty) {
        _listed = [for (final a in (await _listApps())['apps'] as List) a as Map<String, dynamic>];
      }
      final clients = dockClients(await _hyprland.clients());
      _clients = clients;
      final items = dockItems(_listed, dock.pinned(), clients);
      final active = clients.where((c) => c['focusHistoryID'] == 0).firstOrNull?['address'];
      return {
        'items': [
          for (final (app, windows, pinned) in items)
            {
              'key': app['key'],
              'desktop_id': app['desktop_id'],
              'name': app['name'],
              'icon_file': app['icon_file'],
              'actions': [
                for (final a in (app['actions'] as List? ?? const []).take(6))
                  if (a is Map) {'id': a['id'], 'name': a['name']},
              ],
              'pinned': pinned,
              'windows': [for (final w in windows) if (Hyprland.validAddress(w['address'])) w['address']],
              'new_window_action': hasNewWindowAction(app),
            },
        ],
        'active': Hyprland.validAddress(active) ? active : null,
      };
    },
    // A click: not running, start it; running, its last window; already
    // focused, the next one. Only windows Hyprland lists right now.
    'dock.activate': (params) async {
      final app = _app(params);
      final clients = dockClients(await _hyprland.clients());
      _clients = clients;
      final windows = [for (final w in dockWindowsOf(app, clients)) if (Hyprland.validAddress(w['address'])) w];
      if (windows.isEmpty) return _launch(params, null);
      final active = windows.indexWhere((w) => w['focusHistoryID'] == 0);
      final target = windows[active >= 0 ? (active + 1) % windows.length : 0]['address'] as String;
      if (!await _hyprland.focus(target)) throw ServiceError('focus_failed');
      return {'focused': target};
    },
    'dock.close': (params) async {
      final app = _app(params);
      final clients = dockClients(await _hyprland.clients());
      _clients = clients;
      var closed = 0;
      for (final w in dockWindowsOf(app, clients)) {
        if (Hyprland.validAddress(w['address']) && await _hyprland.closeWindow(w['address'] as String)) closed++;
      }
      return {'closed': closed};
    },
    // The dock process (`maprisma-launcher --dock`): a running one re-reads its settings.
    'dock.start': (_) async {
      final state = await _dockState();
      if (state['available'] != true || (state['settings'] as Map)['dock_enabled'] != true) {
        return {'started': false, 'reason': state['reason'] ?? 'off'};
      }
      return {'started': await startDetached([executable, '--dock'], session)};
    },
    'dock.open_manager': (_) async {
      if (!await startDetached([executable, '--toggle'], session)) throw ServiceError('launch_failed');
      return {'started': true};
    },
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

  /// The dock's settings, the edge it really uses (never the bar's), its
  /// sizes, the theme, and whether it can run here.
  Future<Map<String, dynamic>> _dockState() async {
    final values = dock.read();
    final bar = barPosition(session);
    final (band, item, room) = dockSizes(values);
    final omarchy = desktop is OmarchyDesktop && _hyprland.available;
    final library = layerShellInstalled();
    final look = await desktop.look();
    return {
      'settings': values,
      'bar': bar,
      'edge': dockEdge(values, bar),
      'sizes': {'band': band, 'item': item, 'room': room, 'grow': dockGrow(values)},
      'available': omarchy && library,
      'reason': !omarchy ? 'not_omarchy' : (!library ? 'no_layer_shell' : null),
      'look': look,
      'indicator_color': dockIndicatorColor(values, look['colors'] as Map? ?? const {}),
      'corners': settings.read()['corners'],
      // The dock follows these files (the app's settings and icons, the bar's edge).
      'watch': [store.path('settings.json'), store.path('icons.json'), p.join(session.home, '.config/omarchy/shell.json')],
    };
  }

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
    final chosen = _iconChoices.load();
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
        // icons.apply: the icon chosen by hand, else the entry's own.
        'icon_file': _chosenIcon(chosen[app['desktop_id']], icons) ??
            icons.lookup(app['icon'] as String? ?? '') ??
            icons.lookup('application-x-executable'),
        'icon_chosen': chosen.containsKey(app['desktop_id']),
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

  /// A chosen icon's file: ours (when still there) or the theme's.
  static String? _chosenIcon(String? chosen, IconTheme icons) {
    if (chosen == null) return null;
    if (chosen.startsWith('/')) return File(chosen).existsSync() ? chosen : null;
    return icons.lookup(chosen);
  }

  static String? _color(Map<String, dynamic> params) {
    final c = params['color'];
    return c is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(c) ? c : null;
  }

  Map<String, dynamic> _plugin(Map<String, dynamic> params) {
    final plugin = _pluginList[params['plugin_id']];
    if (plugin == null) throw ServiceError('unknown_plugin');
    return plugin;
  }

  /// How a normal start runs the app (for Hyprland's exec with a rule):
  /// uwsm-app with the desktop file on Omarchy, else the entry's own argv.
  List<String> _startArgv(Map app) {
    if (app['argv'] case final List argv when argv.isNotEmpty) return [for (final a in argv) '$a'];
    final path = app['desktop_path'] as String? ?? '';
    final uwsm = session.which('uwsm-app');
    if (path.isNotEmpty && uwsm != null) return [uwsm, '--', path];
    final command = path.isEmpty ? null : desktopCommand(path, session);
    if (command == null) throw ServiceError('launch_failed');
    return command.argv;
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
    // The app's own terminal needs no outside one; packages.install does.
    final terminal = desktop.terminal();
    final argv = _managers.installCommand(manager, found, terminal ?? const []);
    if (argv == null) throw ServiceError('not_found');
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

  PtySession _term(Map<String, dynamic> params) =>
      _terms['${params['id']}'] ?? (throw ServiceError('not_found'));

  /// A terminal line without the outside terminal's "Press Enter" at the end.
  static List<String> _bare(List<String> argv) => [
    for (final a in argv) a.replaceAll("; echo; read -r -p 'Press Enter to close. ' _", ''),
  ];

  /// What the app's terminal runs for an action, and the line it shows.
  Future<(List<String>, String)> _termCommand(Map<String, dynamic> params) async {
    switch (params['action']) {
      case 'install':
        final manager = _string(params, 'manager'), package = _string(params, 'package');
        final found = _found.where((f) => f['manager'] == manager && f['package'] == package).firstOrNull;
        if (found == null || !_enabledManagers().contains(manager)) throw ServiceError('not_found');
        final argv = _managers.installCommand(manager, found, const []);
        if (argv == null) throw ServiceError('not_found');
        return (_bare(argv), _shownCommand(argv));
      case 'uninstall':
        final app = _app(params);
        final plan = await _uninstallPlan(app);
        final what = plan['what'] as String?;
        if (what == null) throw ServiceError('cannot_uninstall');
        List<String>? argv;
        if (plan['kind'] == 'package') {
          argv = _managers.removeCommand(plan['manager'] as String, what, const []);
        } else if (plan['kind'] == 'omarchy' && plan['how'] == 'package' && validPackage(what)) {
          // omarchy-remove-launcher-entry runs this in its own terminal.
          argv = ['sh', '-c', 'sudo pacman -Rns -- "\$1"', 'uninstall', what];
        } else if (plan['kind'] == 'omarchy' && plan['how'] == 'flatpak' && validPackage(what)) {
          argv = ['sh', '-c', 'flatpak uninstall -- "\$1"', 'uninstall', what];
        }
        // Other kinds (trash, web apps, a Flatpak alone) need no terminal.
        if (argv == null) throw ServiceError('not_terminal');
        return (_bare(argv), _shownCommand(argv));
      case 'system':
        final argv = desktop.systemUpdateInner();
        if (argv == null) throw ServiceError('not_terminal');
        return (argv, argv.length == 3 && argv[1] == '-c' ? argv[2] : argv.map(p.basename).join(' '));
      default:
        throw ServiceError('bad_params');
    }
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
    // Omarchy: its own omarchy-remove-launcher-entry decides how (as the old
    // App Manager did), also for Omarchy's web apps and TUIs. Browser-made web
    // apps stay the browser's.
    final remover = session.which('omarchy-remove-launcher-entry');
    if (desktop is OmarchyDesktop && remover != null && desktopPath.isNotEmpty && plan.$1 != 'webapp') {
      final how = await _omarchyRemoval(app);
      if (how != null) {
        if (how.$1 == 'package' && (desktop as OmarchyDesktop).basePackages.contains(how.$2)) warnings.add('omarchy');
        return {'kind': 'omarchy', 'how': how.$1, 'what': how.$2, 'warnings': warnings};
      }
    }
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

  /// What omarchy-remove-launcher-entry will do, in its own order: Omarchy
  /// web app, TUI, your own entry, a pacman package, a Flatpak; null: nothing.
  Future<(String, String)?> _omarchyRemoval(Map app) async {
    final path = app['desktop_path'] as String;
    final text = readDesktopFile(path);
    if (text == null) return null;
    final exec = RegExp(r'^Exec=(.*)$', multiLine: true).firstMatch(text)?[1] ?? '';
    final name = '${app['name']}';
    if (RegExp(r'omarchy-launch-webapp|omarchy-webapp-handler').hasMatch(exec)) return ('webapp', name);
    if (RegExp(r'(^|\s)(\$TERMINAL|xdg-terminal-exec)\s.*-e(\s|$)').hasMatch(exec)) return ('tui', name);
    final env = session.environment;
    final userApps = p.join(
      env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : p.join(session.home, '.local/share'),
      'applications',
    );
    if (p.dirname(path) == userApps) return ('own', name);
    final owner = await _managers.ownerOf(path);
    if (owner != null && owner.$1 == 'pacman') return ('package', owner.$2);
    if (app['sandboxed'] == true && path.contains('/flatpak/')) return ('flatpak', app['desktop_id'] as String);
    return null;
  }

  Future<Map<String, dynamic>> _uninstall(Map app) async {
    final plan = await _uninstallPlan(app);
    final what = plan['what'] as String?;
    switch (plan['kind']) {
      case 'omarchy':
        final remover = session.which('omarchy-remove-launcher-entry')!;
        final argv = [remover, app['desktop_id'] as String, '${app['name']}'];
        // Packages and Flatpaks open Omarchy's floating terminal; the rest is done at once.
        if (plan['how'] == 'package' || plan['how'] == 'flatpak') {
          if (!await startDetached(argv, session)) throw ServiceError('uninstall_failed');
          return {'started': true};
        }
        final out = await readBoundedText(argv, timeout: const Duration(seconds: 60), environment: session.environment);
        if (out == null) throw ServiceError('uninstall_failed');
        return {'done': true};
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

  void dispose() {
    for (final t in _terms.values) {
      t.close();
    }
    _terms.clear();
  }
}
