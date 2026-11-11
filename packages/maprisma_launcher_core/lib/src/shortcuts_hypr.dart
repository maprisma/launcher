/// Global app shortcuts on Omarchy (Hyprland), as the Omarchy plugin's
/// shortcuts.py: the state is rendered to a Lua module that hyprland.lua
/// requires last, so these shortcuts win over Omarchy's defaults and the
/// user's own binds. Taking or turning off another binding is an
/// `hl.unbind` in that module: removing the shortcut gives the key back on
/// the next reload. The user's own files are only read.
library;

import 'package:path/path.dart' as p;

import 'shlex.dart';
import 'shortcuts.dart';

const modAliases = {
  'SUPER': 'SUPER', 'WIN': 'SUPER', 'LOGO': 'SUPER', 'MOD4': 'SUPER', 'META': 'SUPER',
  'SHIFT': 'SHIFT',
  'CTRL': 'CTRL', 'CONTROL': 'CTRL',
  'ALT': 'ALT', 'MOD1': 'ALT',
};

// o.rebind and o.bind_hold (push-to-talk) came with Omarchy 4.5; 4.0 has o.bind and o.bind_toggle.
final _bindRe = RegExp(r'\b(?:o\.(?:re)?bind(?:_toggle|_hold)?|hl\.bind)\(\s*"([^"]+)"\s*(?:,\s*"([^"]*)")?(.*)');
final _unbindRe = RegExp(r'\bhl\.unbind\(\s*"([^"]+)"');
final _webappRe = RegExp(r'\bwebapp\s*=\s*"([^"]+)"');
final _omarchyRe = RegExp(r'\bomarchy\s*=\s*"([^"]+)"');
final _tuiRe = RegExp(r'\btui\s*=\s*"([^"]+)"');
final _urlRe = RegExp('https?://[^\\s"\']+');
final _pluginIdRe = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');

/// Omarchy launch targets that open whichever app the user picked as default.
const defaultAppRoles = ['terminal', 'browser', 'editor'];

/// parse_combo: "SUPER + SHIFT + B" → a combo (keycodes allowed).
Combo? parseHyprCombo(String? text) {
  final parts = [for (final part in (text ?? '').split(RegExp('[+,]'))) if (part.trim().isNotEmpty) part.trim()];
  if (parts.isEmpty) return null;
  final mods = <String>{};
  for (final part in parts.sublist(0, parts.length - 1)) {
    final mod = modAliases[part.toUpperCase()];
    if (mod == null) return null;
    mods.add(mod);
  }
  return makeCombo(mods.toList(), parts.last, codes: true);
}

/// combo_string: Hyprland's syntax, "SUPER + ALT + F".
String comboString(Map combo) => [...combo['mods'] as List, combo['key']].join(' + ');

/// parse_live_binds: the global (non-submap) keyboard binds of `hyprctl binds`.
List<Map<String, dynamic>> parseLiveBinds(String text) {
  final binds = <Map<String, dynamic>>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final fields = <String, String>{};
    for (final line in block.split(RegExp(r'\r\n|\r|\n'))) {
      final stripped = line.trim();
      final i = stripped.indexOf(':');
      if (i < 0) continue;
      final name = stripped.substring(0, i);
      if (name.isNotEmpty && !fields.containsKey(name)) fields[name] = stripped.substring(i + 1).trim();
    }
    if (!fields.containsKey('modmask') || (fields['submap'] ?? '').isNotEmpty) continue;
    var key = fields['key'] ?? '';
    // Keycode binds report the whole combo string as their key.
    if (key.contains('code:')) key = key.split('+').last.trim();
    if (key.isEmpty || key.startsWith('mouse')) continue;
    final mask = int.tryParse(fields['modmask']!.trim());
    if (mask == null) continue;
    binds.add({'mask': mask, 'key': key.toLowerCase(), 'description': fields['description'] ?? ''});
  }
  return binds;
}

/// _strip_lua_comment: the line up to a `--` comment, keeping `--` in strings.
String stripLuaComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (line.startsWith('--', i)) {
      return line.substring(0, i);
    }
  }
  return line;
}

List<String> _lines(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// parse_user_binds: literal binds still in effect from the user's files
/// (name, text), and combos unbound without binding again. Later lines win.
(List<Map<String, dynamic>>, Set<String>) parseUserBinds(List<(String, String)> files) {
  var binds = <Map<String, dynamic>>[];
  final unbinds = <String>{};
  for (final (name, text) in files) {
    for (final line in _lines(text)) {
      final code = stripLuaComment(line);
      final match = _bindRe.firstMatch(code);
      if (match != null) {
        final combo = parseHyprCombo(match[1]);
        if (combo != null) {
          unbinds.remove(comboId(combo));
          var desc = match[2] ?? '';
          if (desc.isEmpty) desc = RegExp(r'description\s*=\s*"([^"]*)"').firstMatch(code)?[1] ?? '';
          binds.add({'combo': combo, 'description': desc, 'command': match[3]!, 'file': name});
        }
        continue;
      }
      final unbind = _unbindRe.firstMatch(code);
      final combo = unbind == null ? null : parseHyprCombo(unbind[1]);
      if (combo != null) {
        final cid = comboId(combo);
        binds = [for (final b in binds) if (comboId(b['combo']) != cid) b];
        unbinds.add(cid);
      }
    }
  }
  return (binds, unbinds);
}

/// load_state (Omarchy plugin): shortcuts may have two steps (`then`); a
/// turned-off binding is just its combo, the unbind does the rest.
Map<String, dynamic> cleanHyprState(Object? data, {String selfKey = '', String selfName = ''}) {
  final apps = data is Map ? data['apps'] : null;
  if (apps is! Map) return {'apps': <String, dynamic>{}};
  final clean = <String, dynamic>{};
  for (final MapEntry(key: appId, value: entry) in apps.entries) {
    if (entry is! Map) continue;
    final shortcuts = <Combo>[];
    for (final item in entry['shortcuts'] is List ? entry['shortcuts'] as List : const []) {
      final combo = item is Map
          ? makeCombo(item['mods'] ?? const [], item['key'] ?? '', then: item['then'], codes: true)
          : null;
      if (combo == null) continue;
      combo['replaces'] = cut(item.containsKey('replaces') ? pyStrOf(item['replaces']) : '', 120);
      final action = item.containsKey('action') ? pyStrOf(item['action']) : '';
      combo['action'] = actionIdRe.hasMatch(action) ? action : '';
      shortcuts.add(combo);
    }
    final disabled = <Combo>[];
    for (final item in entry['disabled'] is List ? entry['disabled'] as List : const []) {
      final combo = item is Map ? makeCombo(item['mods'] ?? const [], item['key'] ?? '', codes: true) : null;
      if (combo == null) continue;
      combo['description'] = cut(item.containsKey('description') ? pyStrOf(item['description']) : '', 120);
      combo['source'] = cut(item.containsKey('source') ? pyStrOf(item['source']) : '', 60);
      disabled.add(combo);
    }
    final launch = entry['launch'];
    if ((shortcuts.isNotEmpty || disabled.isNotEmpty) &&
        launch is List &&
        launch.isNotEmpty &&
        launch.every((a) => a is String)) {
      clean['$appId'] = {
        'name': selfKey.isNotEmpty && '$appId' == selfKey
            ? selfName
            : cut(entry.containsKey('name') ? pyStrOf(entry['name']) : '$appId', 120),
        'launch': [...launch],
        'shortcuts': shortcuts,
        'disabled': disabled,
      };
    }
  }
  return {'apps': clean};
}

// A shell plugin's shortcut toggles it, like Omarchy's own Clipboard key.
const pluginToggle = ['omarchy-shell', 'shell', 'toggle'];

/// plugin_toggle_id: the plugin id when launch toggles a shell plugin.
String? pluginToggleId(List launch) =>
    launch.length == 4 &&
        launch[0] == pluginToggle[0] &&
        launch[1] == pluginToggle[1] &&
        launch[2] == pluginToggle[2] &&
        _pluginIdRe.hasMatch('${launch[3]}')
    ? '${launch[3]}'
    : null;

/// tray_launch_id / is_self_toggle: the old plugin's tray icons and its own
/// toggle script, kept so a state written by it renders the same.
String? trayLaunchId(List launch) =>
    launch.length == 2 && p.basename('${launch[0]}') == 'tray.py' && _pluginIdRe.hasMatch('${launch[1]}')
    ? '${launch[1]}'
    : null;
bool isSelfToggle(List launch) => launch.length == 1 && p.basename('${launch[0]}') == 'launcher-toggle';

/// runs_directly: shell plugins, tray icons and the launcher itself are
/// commands, not apps for uwsm-app.
bool runsDirectly(List launch) => pluginToggleId(launch) != null || trayLaunchId(launch) != null || isSelfToggle(launch);

/// shortcut_launch: the argv of a shortcut, the app or one of its desktop
/// actions; [desktopArg] is uwsm_desktop_arg (a valid desktop file id).
List<String> shortcutLaunch(List launch, String action, String Function(String) desktopArg) {
  final words = [for (final a in launch) '$a'];
  if (words.length == 1 && words[0].endsWith('.desktop')) {
    final desktop = desktopArg(words[0]);
    return [action.isNotEmpty ? '$desktop:$action' : desktop];
  }
  if (action.isNotEmpty && (trayLaunchId(words) != null || isSelfToggle(words))) return [...words, action];
  return words;
}

String _normalizeUrl(String url) => url
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp('^https?://'), '')
    .replaceFirst(RegExp(r'^www\.'), '')
    .replaceFirst(RegExp(r'/+$'), '');

/// Bindings (Omarchy plugin): who owns which key combination right now.
/// [live] is `hyprctl binds`, [user] the user's files, [defaults] Omarchy's
/// stock binding files; [defaultApps] what `omarchy = "terminal"` etc. open.
final class HyprBindings implements ShortcutBindings {
  HyprBindings(
    this.state, {
    required this.live,
    required (List<Map<String, dynamic>>, Set<String>) user,
    required this.defaultBinds,
    this.mainMods,
    this.defaultApps = const {},
  }) : userBinds = user.$1,
       userUnbinds = user.$2;

  final Map<String, dynamic> state;
  final List<Map<String, dynamic>> live;
  final List<Map<String, dynamic>> userBinds;
  final Set<String> userUnbinds;
  final List<Map<String, dynamic>> defaultBinds;
  final List<String>? mainMods;
  final Map<String, String> defaultApps;

  Iterable<MapEntry<String, dynamic>> get _apps => (state['apps'] as Map<String, dynamic>).entries;

  static bool _matches(Map sc, Map combo, Set<String> ids) =>
      modmask(sc) == modmask(combo) &&
      ids.contains((sc['key'] as String).toLowerCase()) &&
      ((sc['then'] as String?) ?? '').toLowerCase() == ((combo['then'] as String?) ?? '').toLowerCase();

  static Set<String> _ids(Map combo) => {(combo['key'] as String).toLowerCase()};

  (String?, Map?) _launcherOwner(Map combo, Set<String> ids) {
    for (final MapEntry(key: id, value: entry) in _apps) {
      for (final sc in entry['shortcuts'] as List) {
        if (_matches(sc, combo, ids)) return (id, entry);
      }
    }
    return (null, null);
  }

  /// A launcher two-step shortcut whose first step is combo.
  (Map?, Map?) _sequenceAfter(Map combo, Set<String> ids) {
    for (final e in _apps) {
      for (final sc in e.value['shortcuts'] as List) {
        if ((sc['then'] ?? '') != '' && _matches(leader(sc), combo, ids)) return (e.value, sc);
      }
    }
    return (null, null);
  }

  static String _launcherAction(Map entry, Map combo, Set<String> ids) {
    for (final sc in entry['shortcuts'] as List) {
      if (_matches(sc, combo, ids)) return sc['action'] as String? ?? '';
    }
    return '';
  }

  Map<String, dynamic>? _userBind(Map combo, Set<String> ids) {
    final mask = modmask(combo);
    Map<String, dynamic>? found;
    for (final bind in userBinds) {
      // Later definitions win, like Hyprland.
      if (modmask(bind['combo']) == mask && ids.contains((bind['combo']['key'] as String).toLowerCase())) found = bind;
    }
    return found;
  }

  bool _disabledByLauncher(Map combo, Set<String> ids) {
    final mask = modmask(combo);
    return _apps.any(
      (e) => (e.value['disabled'] as List).any((d) => modmask(d) == mask && ids.contains((d['key'] as String).toLowerCase())),
    );
  }

  /// classify: (level, description) for assigning combo to appId.
  @override
  (String, String) classify(Map combo, String appId, {Map? app, String action = ''}) {
    final ids = _ids(combo);
    final (ownerId, owner) = _launcherOwner(combo, ids);
    if (ownerId == appId) {
      final current = _launcherAction(owner!, combo, ids);
      return current == action ? (levelSame, owner['name'] as String) : (levelRetarget, current);
    }
    if (ownerId != null) return (levelLauncher, owner!['name'] as String);
    if ((combo['then'] ?? '') != '') return classifyFirstStep(leader(combo));
    final (entry, sequence) = _sequenceAfter(combo, ids);
    if (sequence != null) {
      // The first step of a two-step shortcut cannot open anything itself.
      return (levelLauncher, '${entry!['name']} (${comboLabel(sequence)})');
    }
    if (app != null) {
      // Another binding already does exactly this: assigning would only duplicate it.
      for (final bind in externalShortcuts(app)) {
        if (modmask(bind['combo']) == modmask(combo) && ids.contains((bind['combo']['key'] as String).toLowerCase())) {
          if (bind['action'] == action) return (levelSame, bind['description'] as String);
          break;
        }
      }
    }
    return _externalLevel(combo, ids);
  }

  /// classify_first_step: free when other two-step shortcuts already start
  /// with it (they share it), otherwise taken by whatever has this combo.
  (String, String) classifyFirstStep(Map first) {
    final ids = _ids(first);
    final (ownerId, owner) = _launcherOwner(first, ids);
    if (ownerId != null) return (levelLauncher, owner!['name'] as String);
    if (_sequenceAfter(first, ids).$2 != null) return (levelFree, '');
    return _externalLevel(first, ids);
  }

  (String, String) _externalLevel(Map combo, Set<String> ids) {
    final mask = modmask(combo);
    final hits = [for (final b in live) if (b['mask'] == mask && ids.contains(b['key'])) b];
    final user = _userBind(combo, ids);
    if (user != null && (hits.isNotEmpty || live.isEmpty)) {
      final own = user['description'] as String;
      final fromLive = hits.isNotEmpty ? hits.last['description'] as String : '';
      return (levelCustom, own.isNotEmpty ? own : (fromLive.isNotEmpty ? fromLive : 'custom binding'));
    }
    if (hits.isNotEmpty && !_disabledByLauncher(combo, ids)) {
      final d = hits.last['description'] as String;
      return (levelDesktop, d.isNotEmpty ? d : 'Omarchy binding');
    }
    return (levelFree, '');
  }

  /// used_letters: keys taken with the main modifiers (live, user files, launcher).
  Set<String> usedLetters() {
    final main = makeCombo(mainMods ?? defaultMods, 'A');
    final mask = main != null ? modmask(main) : modBits['SUPER']! | modBits['SHIFT']!;
    return {
      for (final b in live) if (b['mask'] == mask) b['key'] as String,
      for (final b in userBinds) if (modmask(b['combo']) == mask) (b['combo']['key'] as String).toLowerCase(),
      for (final e in _apps)
        for (final sc in e.value['shortcuts'] as List) if (modmask(sc) == mask) (sc['key'] as String).toLowerCase(),
    };
  }

  @override
  List<Combo> suggestions(Map app, String appId, {List<String>? mods, int limit = 8}) =>
      suggestCombos(app, usedLetters(), (c) => classify(c, appId).$1, mods: mods, limit: limit);

  /// Hyprland's binds are taken by an unbind in the module, not from a place.
  @override
  String takenFrom(Map combo) => '';

  List<Map<String, dynamic>>? _active;

  /// active_default_binds: Omarchy defaults Hyprland actually has: not
  /// overridden by the user, not gated off.
  List<Map<String, dynamic>> activeDefaultBinds() => _active ??= () {
    final userIds = {for (final b in userBinds) comboId(b['combo']), ...userUnbinds};
    final liveKeys = {for (final b in live) '${b['mask']}|${b['key']}|${b['description']}'};
    return [
      for (final bind in defaultBinds)
        if (!userIds.contains(comboId(bind['combo'])) &&
            liveKeys.contains(
              '${modmask(bind['combo'])}|${(bind['combo']['key'] as String).toLowerCase()}|${bind['description']}',
            ))
          bind,
    ];
  }();

  /// external_shortcuts: hand-written user binds and live Omarchy defaults
  /// that appear to launch this app, each with the action it opens.
  @override
  List<Map<String, dynamic>> externalShortcuts(Map app) {
    final desktopId = app['desktop_id'] as String? ?? '';
    final needles = {if (desktopId.isNotEmpty) desktopId.toLowerCase()};
    final exec = app['exec'] as String? ?? '';
    var program = '';
    try {
      final words = shlexSplit(exec);
      if (words.isNotEmpty) program = p.basename(words.first).toLowerCase();
    } on ShlexError {
      program = '';
    }
    final urls = {for (final m in _urlRe.allMatches(exec)) _normalizeUrl(m[0]!)};
    final isWebApp = exec.contains('--app-id') || program == 'omarchy-launch-webapp';
    final name = '${app['name'] ?? ''}'.toLowerCase();
    String noSuffix(String s) => s.endsWith('.desktop') ? s.substring(0, s.length - 8) : s;
    // org.gnome.Nautilus → nautilus, the name omarchy-launch-* uses.
    final shortId = noSuffix(desktopId.toLowerCase()).split('.').last;
    final appIds = {noSuffix(desktopId.toLowerCase()), program, shortId}..remove('');

    List<String> actionArgs(Map action) {
      try {
        final argv = shlexSplit('${action['exec'] ?? ''}');
        return [for (final a in argv.skip(1)) if (!a.startsWith('%')) a.toLowerCase()];
      } on ShlexError {
        return const [];
      }
    }

    /// The action whose extra arguments (e.g. --incognito) the command carries.
    String actionFrom(Set<String> words) {
      var best = '', bestArgs = 0;
      for (final action in (app['actions'] as List? ?? const [])) {
        final extra = actionArgs(action as Map);
        if (extra.isNotEmpty && extra.every(words.contains) && extra.length > bestArgs) {
          best = action['id'] as String;
          bestArgs = extra.length;
        }
      }
      return best;
    }

    String? launchesApp(Map bind) {
      final raw = bind['command'] as String;
      final command = raw.toLowerCase();
      final webapp = _webappRe.firstMatch(raw);
      if (webapp != null) {
        final hit = urls.contains(_normalizeUrl(webapp[1]!)) ||
            (isWebApp && name.isNotEmpty && name == (bind['description'] as String).toLowerCase());
        return hit ? '' : null;
      }
      final omarchy = _omarchyRe.firstMatch(raw);
      if (omarchy != null) {
        final parts = omarchy[1]!.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (parts.isEmpty) return null;
        final base = parts.first, args = parts.sublist(1);
        if (defaultAppRoles.contains(base)) {
          final chosen = (defaultApps[base] ?? '').toLowerCase();
          // Terminal and browser resolve to a desktop id, so web apps and
          // terminal apps running on them do not match; the editor is a program.
          final own = base == 'editor' ? {program} : {noSuffix(desktopId.toLowerCase())};
          if (chosen.isEmpty || !own.contains(chosen)) return null;
          if (args.isEmpty) return '';
          return args.length == 1 && args.first == '--private' ? privateAction(app) : null;
        }
        return args.isEmpty && appIds.contains(base) ? '' : null;
      }
      final tui = _tuiRe.firstMatch(raw);
      if (tui != null) {
        try {
          final words = shlexSplit(tui[1]!);
          if (words.isEmpty) return null;
          return appIds.contains(p.basename(words.first).toLowerCase()) ? '' : null;
        } on ShlexError {
          return null;
        }
      }
      final words = {for (final m in RegExp(r'[\w.\-]+').allMatches(command)) m[0]!};
      if (!(command.contains('launch') || command.contains('exec') || command.contains('gtk-launch'))) return null;
      final hit = needles.any((n) => words.contains(n) || words.contains('$n.desktop')) ||
          (program.isNotEmpty &&
              !const {'env', 'sh', 'bash', 'flatpak', 'gtk-launch', 'python3', 'omarchy-launch-webapp'}.contains(program) &&
              words.contains(program));
      return hit ? actionFrom(words) : null;
    }

    return [
      for (final bind in userBinds)
        if (launchesApp(bind) case final action?) {...bind, 'action': action},
      for (final bind in activeDefaultBinds())
        if (launchesApp(bind) case final action?) {...bind, 'file': 'Omarchy', 'action': action},
    ];
  }
}

// --- writing -----------------------------------------------------------------

String luaQuoted(Object? value) {
  final out = StringBuffer('"');
  for (final c in '$value'.runes) {
    final ch = String.fromCharCode(c);
    if (ch == '"' || ch == r'\') {
      out.write('\\$ch');
    } else if (ch == '\n') {
      out.write(r'\n');
    } else if (c < 32 || c == 127) {
      out.write('\\${c.toString().padLeft(3, '0')}');
    } else {
      out.write(ch);
    }
  }
  return (out..write('"')).toString();
}

/// lua_comment: one line; control characters (CR, LF, ...) would end it early.
String luaComment(Object? text) =>
    '-- ${String.fromCharCodes([for (final c in '$text'.runes) c < 32 || c == 127 ? 32 : c])}';

/// The names render_lua writes: the header, the key-capture submap (null:
/// none; Maprisma Launcher has no capture) and the two-step prefix.
final class LuaNames {
  const LuaNames({
    this.header = 'Maprisma Launcher (com.maprisma.Launcher)',
    this.capture,
    this.captureEscape = 'SUPER + Escape',
    this.submapPrefix = 'maprisma-launcher-',
    this.appName = 'Maprisma Launcher',
  });
  final String header;
  final String? capture;
  final String captureEscape;
  final String submapPrefix;
  final String appName;

  /// The Omarchy plugin's own names (for the oracle tests).
  static const reference = LuaNames(
    header: 'App Manager (ubruckhaus.simple-launcher-for-fools)',
    capture: 'simple-launcher-capture',
    submapPrefix: 'simple-launcher-',
    appName: 'App Manager',
  );
}

String submapName(Map first, LuaNames names) =>
    names.submapPrefix +
    comboString(first).toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// render_lua: the generated module. Turned-off bindings are unbound before
/// any shortcut is bound, so a key turned off for one app and given to
/// another stays bound; two-step shortcuts get a submap each.
///
/// [plainCommand] is for Hyprland without Omarchy (no `o.bind`, no uwsm-app): the
/// command line of a shortcut, run through `hl.dsp.exec_cmd`.
String renderLua(
  Map state,
  String Function(String) desktopArg, {
  LuaNames names = const LuaNames(),
  String Function(List<String> launch, String action)? plainCommand,
}) {
  final lines = <String>[
    '-- Managed by ${names.header}.',
    '-- Edit shortcuts from the launcher; manual changes here are overwritten.',
    '',
  ];
  final sequences = <String, (Combo, List<(Map, Map, String)>)>{};
  final appsMap = state['apps'] as Map;
  final keys = appsMap.keys.toList();
  mergeSortBy(keys, (k) => (appsMap[k]['name'] as String).toLowerCase());
  final apps = [for (final k in keys) appsMap[k] as Map];
  final disabled = [for (final entry in apps) for (final combo in entry['disabled'] as List) (entry, combo as Map)];
  for (final (entry, combo) in disabled) {
    final description = combo['description'] as String? ?? '';
    final note = description.isNotEmpty ? ' (was: $description)' : '';
    lines
      ..add(luaComment('${entry['name']}: disabled$note'))
      ..add('hl.unbind(${luaQuoted(comboString(combo))})');
  }
  if (disabled.isNotEmpty) lines.add('');
  for (final entry in apps) {
    final shortcuts = entry['shortcuts'] as List;
    if (shortcuts.isEmpty) continue;
    final launch = entry['launch'] as List;
    for (final combo in shortcuts) {
      final action = combo['action'] as String? ?? '';
      final plain = plainCommand?.call([for (final a in launch) '$a'], action);
      final command = plain ?? shortcutLaunch(launch, action, desktopArg).map(shlexQuote).join(' ');
      if ((combo['then'] ?? '') != '') {
        // Plugins and tray icons run directly; uwsm-app is for apps (Omarchy only).
        final line = plain != null || runsDirectly(launch) ? command : 'uwsm-app -- $command';
        final first = leader(combo);
        sequences.putIfAbsent(comboId(first), () => (first, [])).$2.add((entry, combo, line));
        continue;
      }
      final what = action.isNotEmpty ? '${entry['name']}: $action' : entry['name'] as String;
      final replaces = combo['replaces'] as String? ?? '';
      final note = replaces.isNotEmpty ? ' (replaces: $replaces)' : '';
      lines
        ..add(luaComment('$what$note'))
        ..add('hl.unbind(${luaQuoted(comboString(combo))})');
      if (plain != null) {
        lines.add('hl.bind(${luaQuoted(comboString(combo))}, hl.dsp.exec_cmd(${luaQuoted(plain)}), '
            '{ description = ${luaQuoted(cut(what, 160))} })');
      } else {
        final dispatcher = runsDirectly(launch) ? luaQuoted(command) : '{ launch = ${luaQuoted(command)} }';
        lines.add('o.bind(${luaQuoted(comboString(combo))}, ${luaQuoted(entry['name'])}, $dispatcher)');
      }
    }
    lines.add('');
  }
  if (names.capture != null) {
    lines
      ..add(luaComment("Key capture for the launcher's shortcut page"))
      ..add('hl.define_submap("${names.capture}", function() '
          'hl.bind("${names.captureEscape}", hl.dsp.submap("reset")) end)')
      ..add('');
  }
  // Two-step shortcuts: the first step enters a submap where the second key
  // runs the shortcut; any other key leaves it again.
  final groups = sequences.values.toList();
  mergeSortBy(groups, (g) => comboLabel(g.$1));
  for (final (first, items) in groups) {
    final name = submapName(first, names);
    final replaced = {
      for (final (_, c, _) in items)
        if ((c['replaces'] as String? ?? '').isNotEmpty) c['replaces'] as String,
    }.toList()..sort();
    final note = replaced.isNotEmpty ? ' (replaces: ${replaced.join(', ')})' : '';
    lines
      ..add(luaComment('Two-step shortcuts after ${comboLabel(first)}$note'))
      ..add('hl.unbind(${luaQuoted(comboString(first))})')
      ..add('hl.define_submap(${luaQuoted(name)}, function()');
    final sorted = [...items];
    mergeSortBy(sorted, (item) => item.$2['then'] as String);
    for (final (entry, combo, line) in sorted) {
      final action = combo['action'] as String? ?? '';
      final what = action.isNotEmpty ? '${entry['name']}: $action' : entry['name'] as String;
      lines
        ..add('  ${luaComment('${keyLabel(combo['then'] as String)}: $what')}')
        ..add('  hl.bind(${luaQuoted(combo['then'])}, function()')
        ..add('    hl.dispatch(hl.dsp.submap("reset"))')
        ..add('    hl.exec_cmd(${luaQuoted(line)})')
        ..add('  end, { description = ${luaQuoted(what)} })');
    }
    lines
      ..add('  hl.bind("catchall", hl.dsp.submap("reset"))')
      ..add('end)');
    final summary = [for (final (e, c, _) in items) '${keyLabel(c['then'] as String)} ${e['name']}'].join(', ');
    lines
      ..add('hl.bind(${luaQuoted(comboString(first))}, hl.dsp.submap(${luaQuoted(name)}), '
          '{ description = ${luaQuoted(cut('${names.appName}, then: $summary', 160))} })')
      ..add('');
  }
  return lines.join('\n');
}
