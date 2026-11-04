/// The shortcut page's work (launcher.py open_shortcut_page … apply_shortcut):
/// one backend per desktop, picked from the Desktop adapter. GNOME writes
/// custom keybindings through `gsettings`, COSMIC its shortcut file, Omarchy
/// a Hyprland Lua module; any other desktop is read-only (nothing to write to).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'config.dart';
import 'desktop_entries.dart';
import 'desktops.dart';
import 'launch.dart';
import 'posix.dart';
import 'protocol.dart';
import 'shlex.dart';
import 'shortcuts.dart';
import 'shortcuts_hypr.dart';

const stateFile = 'shortcuts.json';

abstract class ShortcutBackend {
  /// The desktop's name in texts ("GNOME's “Switch to application 1”").
  String get label;
  Future<bool> available();
  Map<String, dynamic> clean(Object? data);
  Future<ShortcutBindings> snapshot(Map<String, dynamic> state, List<String> mainMods);

  /// Write the state to the desktop and save it; throws ServiceError.
  Future<void> save(Map<String, dynamic> state);
}

/// Bounded `program args…`: stdout, or null when it fails.
typedef Runner = Future<String?> Function(List<String> argv, {Duration timeout});

Future<String?> boundedRun(
  List<String> argv, {
  Duration timeout = const Duration(seconds: 3),
  Map<String, String>? environment,
}) => readBoundedText(argv, maxBytes: 4 * 1024 * 1024, timeout: timeout, environment: environment);

/// boundedRun in the session's environment.
Runner sessionRun(Session session) =>
    (argv, {timeout = const Duration(seconds: 3)}) => boundedRun(argv, timeout: timeout, environment: session.environment);

// --- GNOME and COSMIC ---------------------------------------------------------------

final class GnomeBackend implements ShortcutBackend {
  GnomeBackend(this.session, this.store, this.settings, {required this.label, this.favorites});
  final Session session;
  final ConfigStore store;
  final KeySettings settings;
  @override
  final String label;

  /// The Dash's favourites (GNOME's Super + 1…9); null on COSMIC.
  final Future<List<String>> Function()? favorites;

  /// Our custom keybindings' paths: …/custom-keybindings/maprisma-launcher-N/.
  static const ownPrefix = 'maprisma-launcher-';

  @override
  Future<bool> available() async {
    try {
      return await settings.available();
    } on Object {
      return false;
    }
  }

  @override
  Map<String, dynamic> clean(Object? data) => cleanGnomeState(data);

  @override
  Future<ShortcutBindings> snapshot(Map<String, dynamic> state, List<String> mainMods) async => GnomeBindings(
    state,
    desktop: await readDesktopBinds(settings),
    custom: await readCustomBinds(settings, ownPrefix),
    favorites: favorites == null ? const [] : await favorites!(),
    mainMods: mainMods,
  );

  /// shortcut_command: the command line the desktop runs for a shortcut
  /// (split by GLib on GNOME, by sh on COSMIC, quoted for both): the desktop
  /// file's own Exec (or its action's) as the app starts it, in a terminal
  /// when it asks for one; an argv entry as it is. The reference ran its
  /// bounded Python helper here; there is no Python on the target system.
  String command(List<String> launch, String action) {
    if (launch.length == 1 && launch[0].endsWith('.desktop')) {
      final found = desktopCommand(launch[0], session, action: action.isEmpty ? null : action);
      if (found == null) throw ServiceError('launch_failed', launch[0]);
      var argv = found.argv;
      if (found.terminal) {
        final terminal = defaultTerminal(session);
        if (terminal == null) throw ServiceError('no_terminal');
        argv = [...terminal, ...argv];
      }
      final env = session.which('env');
      if (found.cwd != null && env != null) argv = [env, '-C', found.cwd!, ...argv];
      return _checked(shlexJoin(argv));
    }
    return _checked(shlexJoin(launch));
  }

  static String _checked(String line) {
    if (line.contains(RegExp(r'[\x00-\x1f\x7f]'))) throw ServiceError('launch_failed');
    return line;
  }

  @override
  Future<void> save(Map<String, dynamic> state) async {
    if (!await available()) throw ServiceError('not_available');
    final previous = clean(store.readJson(stateFile))['applied'] as List;
    final saved = await applyGnome(
      state,
      settings,
      previousApplied: [for (final a in previous) a as Map],
      ownPrefix: ownPrefix,
      command: command,
    );
    store.writeJson(stateFile, saved);
  }
}

/// gsettings on the user's session bus (argv only, bounded).
KeySettings gsettingsProgram(Session session, {Runner? run}) {
  final runner = run ?? sessionRun(session);
  final program = session.which('gsettings');
  return GSettingsProgram((args) async => program == null ? null : runner([program, ...args]));
}

/// The Dash's favourites (org.gnome.shell favorite-apps), file names.
Future<List<String>> gnomeFavorites(Session session, {Runner? run}) async {
  run ??= sessionRun(session);
  final program = session.which('gsettings');
  final out = program == null ? null : await run([program, 'get', 'org.gnome.shell', 'favorite-apps']);
  return out == null ? const [] : parseGVariantStrings(out) ?? const [];
}

CosmicSettings cosmicSettings(Session session, ConfigStore store, {String? defaultsFile}) {
  final config = session.environment['XDG_CONFIG_HOME']?.isNotEmpty == true
      ? session.environment['XDG_CONFIG_HOME']!
      : p.join(session.home, '.config');
  const dir = 'cosmic/com.system76.CosmicSettings.Shortcuts/v1';
  return CosmicSettings(
    customFile: p.join(config, dir, 'custom'),
    defaultsFile: defaultsFile ?? p.join('/usr/share', dir, 'defaults'),
    readTaken: () => store.readJson('cosmic-taken.json'),
    writeTaken: (data) => store.writeJson('cosmic-taken.json', data),
    writeText: writeTextAtomic,
  );
}

// --- Omarchy (Hyprland) ----------------------------------------------------------------

final class HyprBackend implements ShortcutBackend {
  HyprBackend(this.session, this.store, {Runner? run}) : run = run ?? sessionRun(session);
  final Session session;
  final ConfigStore store;
  final Runner run;
  @override
  String get label => 'Omarchy';

  static const module = 'maprisma-launcher-shortcuts';
  String get hyprDir => p.join(session.home, '.config/hypr');
  String get luaFile => p.join(hyprDir, '$module.lua');
  String get mainFile => p.join(hyprDir, 'hyprland.lua');
  static const requireLine = 'require("hypr.$module")';
  String get omarchyRoot => session.environment['OMARCHY_PATH']?.isNotEmpty == true
      ? session.environment['OMARCHY_PATH']!
      : '/usr/share/omarchy';

  @override
  Future<bool> available() async => session.which('hyprctl') != null && File(mainFile).existsSync();

  @override
  Map<String, dynamic> clean(Object? data) => cleanHyprState(data);

  static String? _read(String path) {
    final bytes = Posix.instance.readRegular(path, 1024 * 1024);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  List<(String, String)> _files(String dir, {String? except}) {
    final found = <(String, String)>[];
    try {
      final paths = [
        for (final f in Directory(dir).listSync())
          if (f.path.endsWith('.lua') && p.basename(f.path) != except) f.path,
      ]..sort();
      for (final path in paths) {
        final text = _read(path);
        if (text != null) found.add((p.basename(path), text));
      }
    } on FileSystemException {
      // No folder: no binds.
    }
    return found;
  }

  /// default_app_id: what `omarchy = "<role>"` opens ("" when unknown).
  Future<String> defaultApp(String role) async {
    if (role == 'editor') {
      // omarchy-launch-editor: the saved choice, else nvim.
      final text = _read(p.join(session.home, '.local/state/omarchy/defaults/editor')) ?? '';
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      return words.isEmpty ? 'nvim' : p.basename(words.first);
    }
    final command = role == 'terminal'
        ? ['xdg-terminal-exec', '--print-id']
        : ['xdg-settings', 'get', 'default-web-browser'];
    final program = session.which(command.first);
    if (program == null) return '';
    final env = {...session.environment}..remove('BROWSER');
    final out = await readBoundedText(
      [program, ...command.skip(1)],
      environment: env,
      timeout: const Duration(seconds: 2),
    );
    final lines = (out ?? '').trim().split('\n');
    // An entry may carry an action suffix: "foot.desktop:server".
    final first = lines.first.split(':').first;
    return first.endsWith('.desktop') ? first.substring(0, first.length - 8) : first;
  }

  @override
  Future<ShortcutBindings> snapshot(Map<String, dynamic> state, List<String> mainMods) async {
    final hyprctl = session.which('hyprctl');
    final binds = hyprctl == null ? null : await run([hyprctl, 'binds']);
    return HyprBindings(
      state,
      live: binds == null ? const [] : parseLiveBinds(binds),
      user: parseUserBinds(_files(hyprDir, except: '$module.lua')),
      defaultBinds: parseUserBinds(_files(p.join(omarchyRoot, 'default/hypr/bindings'))).$1,
      mainMods: mainMods,
      defaultApps: {for (final role in defaultAppRoles) role: await defaultApp(role)},
    );
  }

  /// uwsm_desktop_arg: uwsm-app warns about desktop file names that are no
  /// valid Desktop Entry ID (Omarchy's "Google Maps.desktop"); such entries
  /// are launched through a symlink with a valid name in a private folder.
  String desktopArg(String desktopPath) {
    final name = p.basename(desktopPath);
    if (RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*\.desktop$').hasMatch(name)) return desktopPath;
    var stem = name
        .substring(0, name.length - '.desktop'.length)
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    if (stem.isEmpty) stem = 'app';
    if (!RegExp('^[A-Za-z0-9_]').hasMatch(stem)) stem = 'app-$stem';
    final dir = p.join(session.home, '.local/state/maprisma-launcher/desktop-ids');
    final alias = p.join(dir, '$stem.desktop');
    try {
      if (!Directory(dir).existsSync()) {
        Directory(dir).createSync(recursive: true);
        Process.runSync('chmod', ['700', dir]);
      }
      // Only a private directory of ours: no symlink, nobody else can write.
      final info = FileStat.statSync(dir);
      if (FileSystemEntity.isLinkSync(dir) ||
          info.type != FileSystemEntityType.directory ||
          Posix.instance.ownerOf(dir) != Posix.instance.uid ||
          info.mode & 0x12 != 0) {
        return desktopPath;
      }
      if (FileSystemEntity.isLinkSync(alias) && Link(alias).targetSync() == desktopPath) return alias;
      final tmp = Link(p.join(dir, '.$stem.$pid.${DateTime.now().microsecondsSinceEpoch}'));
      try {
        tmp.createSync(desktopPath); // fails instead of following anything already there
        tmp.renameSync(alias);
      } finally {
        if (FileSystemEntity.isLinkSync(tmp.path)) tmp.deleteSync();
      }
      return alias;
    } on FileSystemException {
      return desktopPath;
    }
  }

  /// _config_errors: reload Hyprland and read its configuration errors.
  Future<String> configErrors() async {
    final hyprctl = session.which('hyprctl');
    if (hyprctl == null) return 'hyprctl not found';
    await run([hyprctl, 'reload'], timeout: const Duration(seconds: 5));
    final out = await run([hyprctl, 'configerrors'], timeout: const Duration(seconds: 5));
    if (out == null) return 'hyprctl configerrors failed';
    final text = out.trim();
    return text.isEmpty || const {'no errors', 'none'}.contains(text.toLowerCase()) ? '' : text;
  }

  /// ensure_required: append the require line to hyprland.lua once, with a backup.
  void ensureRequired() {
    final text = _read(mainFile);
    if (text == null) throw ServiceError('not_available', 'Cannot read $mainFile');
    if (text.contains(requireLine)) return;
    final backup = File('$mainFile.before-maprisma-launcher-shortcuts');
    if (!backup.existsSync()) File(mainFile).copySync(backup.path);
    final suffix = text.endsWith('\n') ? '' : '\n';
    writeTextAtomic(
      mainFile,
      '$text$suffix\n-- Maprisma Launcher app shortcuts (keep last so they override defaults)\n$requireLine\n',
    );
  }

  /// save_and_apply: the state, the module, a reload; on a new
  /// configuration error the previous files come back and the error is raised.
  @override
  Future<void> save(Map<String, dynamic> state) async {
    if (!await available()) throw ServiceError('not_available');
    final oldState = File(store.path(stateFile)).existsSync() ? store.readJson(stateFile) : null;
    final oldLua = File(luaFile).existsSync() ? _read(luaFile) ?? '' : null;
    final before = await configErrors();
    writeTextAtomic(luaFile, renderLua(state, desktopArg));
    ensureRequired();
    store.writeJson(stateFile, state);
    final errors = await configErrors();
    if (errors.isNotEmpty && errors != before) {
      writeTextAtomic(luaFile, oldLua ?? '');
      if (oldState == null) {
        File(store.path(stateFile)).deleteSync();
      } else {
        store.writeJson(stateFile, oldState);
      }
      await configErrors();
      throw ServiceError('not_applied', errors.split('\n').first);
    }
  }
}

// --- the page's operations ----------------------------------------------------------------

/// The backend of a desktop, or null where shortcuts cannot be written.
ShortcutBackend? backendFor(Desktop desktop, ConfigStore store, {String? cosmicDefaults}) => switch (desktop) {
  OmarchyDesktop() => HyprBackend(desktop.session, store),
  GnomeDesktop() => GnomeBackend(
    desktop.session,
    store,
    gsettingsProgram(desktop.session),
    label: 'GNOME',
    favorites: () => gnomeFavorites(desktop.session),
  ),
  CosmicDesktop() => _cosmicBackend(desktop.session, store, cosmicDefaults),
  _ => null,
};

/// COSMIC's shortcut file read at once; one we cannot read or parse means
/// no shortcuts here (read-only), never a broken core.
ShortcutBackend? _cosmicBackend(Session session, ConfigStore store, String? defaults) {
  try {
    return GnomeBackend(session, store, cosmicSettings(session, store, defaultsFile: defaults), label: 'COSMIC');
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

final class ShortcutService {
  ShortcutService(this.backend, this.store);
  final ShortcutBackend? backend;
  final ConfigStore store;
  ShortcutBindings? _bindings;
  Map<String, dynamic>? _state;
  Future<void> _queue = Future.value();

  /// One write at a time: two quick clicks must not interleave their reads.
  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  List<String> defaultMods() {
    final data = store.readJson('settings.json', cap: 64 * 1024);
    return defaultModsFrom(data is Map ? data['shortcut_default_mods'] : null);
  }

  void saveDefaultMods(List<String> mods) {
    final data = store.readJson('settings.json', cap: 64 * 1024);
    store.writeJson('settings.json', {
      ...(data is Map ? data : const {}),
      'shortcut_default_mods': [for (final m in modOrder) if (mods.contains(m)) m],
    });
  }

  Map<String, dynamic> _loadState() => backend!.clean(store.readJson(stateFile, cap: 1024 * 1024));

  Future<(Map<String, dynamic>, ShortcutBindings)> _snapshot({bool fresh = false}) async {
    if (fresh || _bindings == null || _state == null) {
      _state = _loadState();
      _bindings = await backend!.snapshot(_state!, defaultMods());
    }
    return (_state!, _bindings!);
  }

  static List<String> mods(Object? value) {
    if (value is! List || value.any((m) => !modOrder.contains(m))) throw ServiceError('bad_params');
    return [for (final m in modOrder) if (value.contains(m)) m];
  }

  /// A combo of the key map: modifiers and key from the fixed lists only.
  static Combo mapCombo(Map<String, dynamic> params) {
    final key = keyMapKey(params['combo_key']);
    if (key == null) throw ServiceError('bad_params');
    return makeCombo(mods(params['mods']), key)!;
  }

  /// An existing shortcut's combo (it may be a two-step or keycode one).
  static Combo anyCombo(Object? value) {
    if (value is! Map) throw ServiceError('bad_params');
    final combo = makeCombo(mods(value['mods']), value['key'], then: value['then'], codes: true);
    if (combo == null) throw ServiceError('bad_params');
    return combo;
  }

  static String action(Map app, Object? value) {
    if (value == null || value == '') return '';
    final ids = [for (final a in (app['actions'] as List? ?? const [])) a['id']];
    if (value is! String || !ids.contains(value)) throw ServiceError('bad_params');
    return value;
  }

  static Map<String, dynamic> _entry(Map state, String id) =>
      (state['apps'] as Map)[id] as Map<String, dynamic>? ?? {'shortcuts': [], 'disabled': []};

  /// classify_shortcut: classify() for the page: the app, the picked action,
  /// and the shortcut being changed (its own key is free to reuse).
  static (String, String) classifyPage(
    ShortcutBindings bindings,
    Combo combo,
    Map app,
    String action,
    Map? editing,
  ) {
    if (editing != null && comboId(combo) == comboId(editing)) {
      if ((editing['action'] ?? '') == action) return (levelSame, '');
      return (editing['external'] == true ? levelFree : levelRetarget, '');
    }
    return bindings.classify(combo, shortcutAppKey(app), app: app, action: action);
  }

  Map<String, dynamic>? _editing(Map app, Object? value) {
    if (value == null) return null;
    final combo = anyCombo(value);
    return {...combo, 'action': action(app, (value as Map)['action']), 'external': value['external'] == true};
  }

  static Map<String, dynamic> _shown(Map combo) => {
    'mods': combo['mods'],
    'key': combo['key'],
    if ((combo['then'] ?? '') != '') 'then': combo['then'],
    'label': comboLabel(combo),
  };

  /// shortcuts.state: what the page shows for an app (render_shortcut_current,
  /// render_shortcut_suggestions): its shortcuts of any source, the turned-off
  /// ones, and every key of the map with [mods] coloured by its owner.
  Future<Map<String, dynamic>> view(Map app, Map<String, dynamic> params) async {
    final base = {
      'desktop': backend?.label,
      'default_mods': defaultMods(),
      'actions': [
        for (final a in (app['actions'] as List? ?? const [])) {'id': a['id'], 'name': a['name']},
      ],
    };
    if (backend == null || appLaunchArgv(app) == null || !await backend!.available()) {
      return {...base, 'available': false};
    }
    final chosen = mods(params['mods'] ?? const []);
    final picked = action(app, params['action']);
    final editing = _editing(app, params['editing']);
    final (state, bindings) = await _snapshot(fresh: params['fresh'] == true);
    final id = shortcutAppKey(app);
    final entry = _entry(state, id);
    final externals = bindings.externalShortcuts(app);
    final owned = ownedIds(state);
    final disabledIds = {for (final c in entry['disabled'] as List) comboId(c)};
    final current = <Map<String, dynamic>>[
      for (final combo in entry['shortcuts'] as List)
        {
          ..._shown(combo),
          'source': 'launcher',
          'action': combo['action'] ?? '',
          'replaces': combo['replaces'] ?? '',
          'duplicate': externals.any((b) => comboId(b['combo']) == comboId(combo) && b['action'] == (combo['action'] ?? '')),
        },
      for (final bind in externals)
        if (!disabledIds.contains(comboId(bind['combo'])) && !owned.contains(comboId(bind['combo'])))
          {
            ..._shown(bind['combo']),
            'source': 'external',
            'action': bind['action'],
            'file': bind['file'],
            'description': bind['description'],
          },
    ];
    String level(Combo c) => classifyPage(bindings, c, app, picked, editing).$1;
    return {
      ...base,
      'available': true,
      'shortcuts': current,
      'disabled': [
        for (final combo in entry['disabled'] as List)
          {..._shown(combo), 'description': combo['description'] ?? '', 'source': combo['source'] ?? ''},
      ],
      if (chosen.isNotEmpty)
        'keys': [
          for (final key in keyMapKeys)
            if (makeCombo(chosen, key) case final combo?)
              () {
                final (lvl, owner) = classifyPage(bindings, combo, app, picked, editing);
                return {'key': key, 'label': keyLabel(key), 'level': lvl, 'owner': owner};
              }(),
        ]
      else
        'suggestions': [for (final c in bindings.suggestions(app, id)) if (level(c) == levelFree) _shown(c)],
    };
  }

  Future<Map<String, dynamic>> _commit(Map<String, dynamic> state) async {
    final apps = state['apps'] as Map<String, dynamic>;
    // Entries with nothing left go; so do those whose app was uninstalled.
    apps.removeWhere(
      (_, e) =>
          ((e['shortcuts'] as List).isEmpty && (e['disabled'] as List).isEmpty) ||
          launchTargetMissing(e['launch'] as List),
    );
    try {
      await backend!.save(state);
    } on ServiceError {
      rethrow;
    } on Object catch (e) {
      throw ServiceError('not_applied', '$e'.split('\n').first);
    } finally {
      _bindings = null;
    }
    return {'saved': true};
  }

  Map<String, dynamic> _appEntry(Map<String, dynamic> state, Map app) {
    final entry = (state['apps'] as Map<String, dynamic>).putIfAbsent(
      shortcutAppKey(app),
      () => <String, dynamic>{'shortcuts': [], 'disabled': []},
    ) as Map<String, dynamic>;
    entry['name'] = app['name'];
    entry['launch'] = appLaunchArgv(app);
    return entry;
  }

  static Map<String, dynamic> _copy(Map state) => jsonDecode(jsonEncode(state)) as Map<String, dynamic>;

  Future<ShortcutBackend> _writable() async {
    if (backend == null || !await backend!.available()) throw ServiceError('not_available');
    return backend!;
  }

  /// apply_shortcut: give [combo] to the app (or one of its actions); a key
  /// of another launcher shortcut moves here, a key of the desktop or the
  /// user's own shortcut is taken while this one exists. With `editing`, the
  /// shortcut being changed goes (a launcher one) or is turned off (another).
  Future<Map<String, dynamic>> assign(Map app, Map<String, dynamic> params) => _locked(() async {
    await _writable();
    if (appLaunchArgv(app) == null) throw ServiceError('bad_params');
    final combo = mapCombo(params);
    if ((combo['mods'] as List).isEmpty) throw ServiceError('bad_params');
    final picked = action(app, params['action']);
    final editing = _editing(app, params['editing']);
    final (state0, bindings) = await _snapshot(fresh: true);
    final (level, owner) = classifyPage(bindings, combo, app, picked, editing);
    if (level == levelSame) throw ServiceError('refused', 'same');
    final state = _copy(state0);
    final cid = comboId(combo);
    if (level == levelLauncher || level == levelRetarget) {
      for (final e in (state['apps'] as Map).values) {
        e['shortcuts'] = [for (final c in e['shortcuts'] as List) if (!collides(c, combo)) c];
      }
    }
    final entry = _appEntry(state, app);
    entry['disabled'] = [for (final c in entry['disabled'] as List) if (comboId(c) != cid) c];
    final taken = level == levelCustom || level == levelDesktop;
    if (editing != null) {
      final oldId = comboId(editing);
      if (editing['external'] != true) {
        // Dropping it also ends any override it held, so that binding works again.
        entry['shortcuts'] = [for (final c in entry['shortcuts'] as List) if (comboId(c) != oldId) c];
      } else {
        final bind = bindings
            .externalShortcuts(app)
            .where((b) => comboId(b['combo']) == oldId)
            .firstOrNull;
        if (bind == null) throw ServiceError('not_found');
        (entry['disabled'] as List).add(_disabledFrom(bind));
      }
    }
    final added = <String, dynamic>{
      ...combo,
      'replaces': taken ? owner : '',
      'taken_from': taken ? bindings.takenFrom(combo) : '',
      'action': picked,
      // The name in GNOME Settings.
      if (picked.isNotEmpty) 'label': actionName(app, picked),
    };
    (entry['shortcuts'] as List).add(added);
    return {...await _commit(state), 'level': level, 'owner': owner};
  });

  static Map<String, dynamic> _disabledFrom(Map bind) => {
    ...makeCombo(bind['combo']['mods'], bind['combo']['key'], codes: true)!,
    'description': bind['description'],
    'source': bind['file'],
    'where': bind['where'] ?? '',
  };

  /// remove_shortcut: the launcher shortcut goes; a key it took works again.
  Future<Map<String, dynamic>> remove(Map app, Map<String, dynamic> params) => _locked(() async {
    await _writable();
    final cid = comboId(anyCombo(params['combo']));
    final (state0, _) = await _snapshot(fresh: true);
    final state = _copy(state0);
    final entry = _appEntry(state, app);
    final before = (entry['shortcuts'] as List).length;
    entry['shortcuts'] = [for (final c in entry['shortcuts'] as List) if (comboId(c) != cid) c];
    if ((entry['shortcuts'] as List).length == before) throw ServiceError('not_found');
    return _commit(state);
  });

  /// disable_external_shortcut: another binding that opens the app is turned off.
  Future<Map<String, dynamic>> disable(Map app, Map<String, dynamic> params) => _locked(() async {
    await _writable();
    final cid = comboId(anyCombo(params['combo']));
    final (state0, bindings) = await _snapshot(fresh: true);
    final bind = bindings.externalShortcuts(app).where((b) => comboId(b['combo']) == cid).firstOrNull;
    if (bind == null) throw ServiceError('not_found');
    final state = _copy(state0);
    (_appEntry(state, app)['disabled'] as List).add(_disabledFrom(bind));
    return _commit(state);
  });

  /// restore_external_shortcut: a turned-off binding works again.
  Future<Map<String, dynamic>> restore(Map app, Map<String, dynamic> params) => _locked(() async {
    await _writable();
    final cid = comboId(anyCombo(params['combo']));
    final (state0, _) = await _snapshot(fresh: true);
    final state = _copy(state0);
    final entry = _appEntry(state, app);
    entry['disabled'] = [for (final c in entry['disabled'] as List) if (comboId(c) != cid) c];
    return _commit(state);
  });

  /// Every shortcut that opens each of [apps] now, of any source (the
  /// launcher's and the desktop's or user's own, not the turned-off ones):
  /// {app key: [label]}; for Ask AI's facts. Empty where shortcuts cannot be
  /// read; never throws.
  Future<Map<String, List<String>>> allLabels(Map<String, Map> apps) async {
    try {
      if (backend == null || !await backend!.available()) return const {};
      final (state, bindings) = await _snapshot();
      final owned = ownedIds(state);
      final result = <String, List<String>>{};
      for (final MapEntry(:key, :value) in apps.entries) {
        if (appLaunchArgv(value) == null) continue;
        final entry = _entry(state, shortcutAppKey(value));
        final disabledIds = {for (final c in entry['disabled'] as List) comboId(c)};
        final labels = <String>{
          for (final c in entry['shortcuts'] as List) comboLabel(c),
          for (final b in bindings.externalShortcuts(value))
            if (!disabledIds.contains(comboId(b['combo'])) && !owned.contains(comboId(b['combo'])))
              comboLabel(b['combo']),
        };
        if (labels.isNotEmpty) result[key] = labels.toList();
      }
      return result;
    } on Object {
      return const {};
    }
  }

  /// The shortcuts every app has (the list's chips): {app key: [label]}.
  Future<Map<String, dynamic>> labels() async {
    if (backend == null) return {'labels': {}};
    final state = _loadState();
    return {
      'labels': {
        for (final MapEntry(:key, :value) in (state['apps'] as Map<String, dynamic>).entries)
          if ((value['shortcuts'] as List).isNotEmpty)
            key: [for (final c in value['shortcuts'] as List) comboLabel(c)],
      },
    };
  }
}
