/// Global app shortcuts, the parts every desktop shares plus GNOME's and
/// COSMIC's (gnome-launcher shortcuts.py). Hyprland's are in
/// shortcuts_hypr.dart, the per-desktop service in shortcut_service.dart.
///
/// A combo is a map {mods: [SUPER, SHIFT, CTRL, ALT in that order], key,
/// then?} as the references keep it, so states and oracle answers compare 1:1.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'keyboard_layout.dart';

export 'keyboard_layout.dart' show keyRowsFor, detectKeyboardLayout;

import 'posix.dart';
import 'shlex.dart';

typedef Combo = Map<String, dynamic>;

/// Modifier bits, as GDK and Hyprland have them.
const modBits = {'SHIFT': 1, 'CTRL': 4, 'ALT': 8, 'SUPER': 64};
const modOrder = ['SUPER', 'SHIFT', 'CTRL', 'ALT'];
const modLabels = {'SUPER': 'Super', 'SHIFT': 'Shift', 'CTRL': 'Ctrl', 'ALT': 'Alt'};
const defaultMods = ['SUPER', 'SHIFT'];

// Conflict classes, from harmless to dangerous (DESKTOP is Omarchy's
// "omarchy" on Hyprland: the desktop's own binding either way).
const levelFree = 'free',
    levelSame = 'same',
    levelLauncher = 'launcher',
    levelCustom = 'custom',
    levelDesktop = 'desktop',
    // The key already opens this app, but a different action of it.
    levelRetarget = 'retarget';

/// The keys the key map offers and the routes accept (keysym names, as GNOME
/// accelerators, COSMIC's file and Hyprland binds spell them). Nothing else
/// can be assigned, so no other text ever reaches a desktop's settings.
const keyMapRows = usKeyRows;

/// Every key any layout's map offers: what the routes accept.
final keyMapKeys = {for (final rows in keyRowsByLayout.values) for (final row in rows) ...row};

/// The key map's key named [name] in any case ("return" → "Return"), or null.
String? keyMapKey(Object? name) {
  if (name is! String) return null;
  for (final key in keyMapKeys) {
    if (key.toLowerCase() == name.toLowerCase()) return key;
  }
  return null;
}

final _keyRe = RegExp(r'^[A-Za-z0-9_]{1,32}$');
// Hyprland also binds by keycode (code:38).
final _hyprKeyRe = RegExp(r'^(code:\d{1,3}|[A-Za-z0-9_]{1,32})$');
final _accelRe = RegExp(r'^((?:<[A-Za-z0-9]{1,16}>){0,6})([A-Za-z0-9_]{1,32})$');
final actionIdRe = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
const accelMods = {'SUPER': '<Super>', 'SHIFT': '<Shift>', 'CTRL': '<Control>', 'ALT': '<Alt>'};
const accelAliases = {
  'super': 'SUPER', 'shift': 'SHIFT', 'control': 'CTRL', 'ctrl': 'CTRL', 'primary': 'CTRL',
  'alt': 'ALT', 'mod1': 'ALT',
};

/// Python's `str(value or "")` for the references' loose JSON fields.
String pyStr(Object? value) {
  if (value == null || value == false || value == '' || value == 0 || (value is List && value.isEmpty) ||
      (value is Map && value.isEmpty)) {
    return '';
  }
  return value == true ? 'True' : '$value';
}

/// Python's `str(value)` (None stays "None").
String pyStrOf(Object? value) => value == null
    ? 'None'
    : value is bool
    ? (value ? 'True' : 'False')
    : '$value';

/// The first [n] characters (code points, as Python slices).
String cut(String text, int n) {
  final runes = text.runes;
  return runes.length <= n ? text : String.fromCharCodes(runes.take(n));
}

// --- combos ------------------------------------------------------------------

/// _clean_key: the key name, single letters upper case; null when unusable.
String? cleanKey(Object? key, {bool codes = false}) {
  final text = pyStr(key).trim();
  if (!(codes ? _hyprKeyRe : _keyRe).hasMatch(text)) return null;
  return text.length == 1 && RegExp(r'^[A-Za-z]$').hasMatch(text) ? text.toUpperCase() : text;
}

/// The names in a loose `mods` value, as Python iterates it.
Iterable<String> _modNames(Object? mods) => switch (mods) {
  final List l => l.whereType<String>(),
  final String s => s.split(''),
  final Map m => m.keys.whereType<String>(),
  _ => const [],
};

/// make_combo: a canonical combo, or null when a key name is unusable. With
/// [then] (Hyprland only) a two-step shortcut: mods + key, release, then.
Combo? makeCombo(Object? mods, Object? key, {Object? then, bool codes = false}) {
  final clean = cleanKey(key, codes: codes);
  if (clean == null) return null;
  final names = _modNames(mods).toSet();
  final combo = <String, dynamic>{
    'mods': [for (final m in modOrder) if (names.contains(m)) m],
    'key': clean,
  };
  if (pyStr(then).isNotEmpty) {
    final second = cleanKey(then, codes: codes);
    if (second == null) return null;
    combo['then'] = second;
  }
  return combo;
}

int modmask(Map combo) => (combo['mods'] as List).fold(0, (a, m) => a + modBits[m]!);

/// combo_id: the same keys, whatever the case ("mask|key|then").
String comboId(Map combo) =>
    '${modmask(combo)}|${(combo['key'] as String).toLowerCase()}|${((combo['then'] as String?) ?? '').toLowerCase()}';

/// leader: the first step of a combo (the combo itself with one step).
Combo leader(Map combo) => {'mods': [...combo['mods'] as List], 'key': combo['key']};

/// collides: two launcher shortcuts that cannot both exist: the same keys,
/// or one step that is the first step of a two-step shortcut.
bool collides(Map a, Map b) {
  if (comboId(a) == comboId(b)) return true;
  final aThen = (a['then'] ?? '') != '', bThen = (b['then'] ?? '') != '';
  return aThen != bThen && comboId(leader(a)) == comboId(leader(b));
}

/// owned_ids: every key the launcher binds (two-step first steps too).
Set<String> ownedIds(Map state) => {
  for (final entry in (state['apps'] as Map).values)
    for (final combo in entry['shortcuts'] as List) ...{comboId(combo), comboId(leader(combo))},
};

const _gnomePretty = {
  'RETURN': 'Enter', 'SPACE': 'Space', 'ESCAPE': 'Esc', 'BACKSPACE': 'Backspace',
  'TAB': 'Tab', 'COMMA': ',', 'PERIOD': '.', 'SLASH': '/', 'MINUS': '-',
  'EQUAL': '=', 'SEMICOLON': ';', 'APOSTROPHE': "'", 'GRAVE': '`', 'PAGE_UP': 'Page Up',
  'PAGE_DOWN': 'Page Down', 'ABOVE_TAB': 'Above Tab',
};
// The key map's keys the references never named.
const _morePretty = {
  'BRACKETLEFT': '[', 'BRACKETRIGHT': ']', 'BACKSLASH': r'\', 'DELETE': 'Delete',
  'INSERT': 'Insert', 'HOME': 'Home', 'END': 'End',
  // German keys.
  'SSHARP': 'ß', 'UDIAERESIS': 'Ü', 'ODIAERESIS': 'Ö', 'ADIAERESIS': 'Ä', 'PLUS': '+',
  'NUMBERSIGN': '#', 'LESS': '<',
};

/// key_label (gnome-launcher; the Omarchy plugin's lacks Page Up/Down and
/// Above Tab, which its keys never use).
String keyLabel(String key) =>
    _gnomePretty[key.toUpperCase()] ??
    _morePretty[key.toUpperCase()] ??
    (key.length > 1 ? key : key.toUpperCase());

/// combo_label: "Super + Alt + F", two-step "Super + Alt + Space, N".
String comboLabel(Map combo) {
  final label = [for (final m in combo['mods'] as List) modLabels[m]!, keyLabel(combo['key'] as String)].join(' + ');
  final then = combo['then'] as String?;
  return then != null && then.isNotEmpty ? '$label, ${keyLabel(then)}' : label;
}

/// accelerator: GNOME's syntax, `<Super><Shift>b`.
String accelerator(Map combo) {
  final key = combo['key'] as String;
  return [for (final m in combo['mods'] as List) accelMods[m]!].join() + (key.length == 1 ? key.toLowerCase() : key);
}

/// parse_accelerator: a combo from `<Super><Shift>b`, or null (empty,
/// unknown modifiers such as `<Hyper>`, or not a key).
Combo? parseAccelerator(Object? text) {
  final match = _accelRe.firstMatch(pyStr(text).trim());
  if (match == null) return null;
  final mods = <String>{};
  for (final m in RegExp(r'<([^>]+)>').allMatches(match[1]!)) {
    final mod = accelAliases[m[1]!.toLowerCase()];
    if (mod == null) return null;
    mods.add(mod);
  }
  return makeCombo(mods.toList(), match[2]);
}

/// private_action: the app's private/incognito window action id, or null.
String? privateAction(Map app) {
  for (final action in (app['actions'] as List? ?? const [])) {
    if (const ['new-private-window', 'private-window'].contains(action['id']) ||
        RegExp('private|incognito', caseSensitive: false).hasMatch('${action['name'] ?? ''}')) {
      return action['id'] as String;
    }
  }
  return null;
}

String actionName(Map app, String actionId) {
  for (final action in (app['actions'] as List? ?? const [])) {
    if (action['id'] == actionId) return action['name'] as String;
  }
  return actionId;
}

/// app_key: the shortcut state's key of an app.
String shortcutAppKey(Map app) {
  final path = app['desktop_path'] as String? ?? '';
  return path.isNotEmpty ? path : (app['desktop_id'] as String? ?? '');
}

/// app_launch_argv: what a shortcut opens: [desktop file] or the entry's argv.
List<String>? appLaunchArgv(Map app) {
  if (app['argv'] case final List argv) return [for (final a in argv) '$a'];
  final path = app['desktop_path'] as String? ?? '';
  return path.isNotEmpty ? [path] : null;
}

/// launch_target_missing: a shortcut's app is gone: its desktop file, or an
/// AppImage deleted from a folder that is still there (not an unmounted drive).
bool launchTargetMissing(List launch) {
  if (launch.length != 1) return false;
  final path = '${launch[0]}';
  if (!p.isAbsolute(path) || FileSystemEntity.typeSync(path, followLinks: true) != FileSystemEntityType.notFound) {
    return false;
  }
  return p.extension(path) == '.desktop' || Directory(p.dirname(path)).existsSync();
}

/// The modifiers preselected for apps without a shortcut (load_default_mods),
/// from the settings' shortcut_default_mods.
List<String> defaultModsFrom(Object? mods) {
  if (mods is List) {
    final clean = [for (final m in modOrder) if (mods.contains(m)) m];
    if (clean.isNotEmpty) return clean;
  }
  return [...defaultMods];
}

// --- GNOME's state -----------------------------------------------------------

const mediaKeys = 'org.gnome.settings-daemon.plugins.media-keys';
const customSchema = '$mediaKeys.custom-keybinding';
const customListKey = 'custom-keybindings';
const customBase = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/';

/// Schemas whose string-list keys are GNOME's own key bindings.
const bindingSchemas = [
  'org.gnome.desktop.wm.keybindings', 'org.gnome.shell.keybindings',
  'org.gnome.mutter.keybindings', 'org.gnome.mutter.wayland.keybindings', mediaKeys,
];
final favoriteKey = RegExp(r'^(?:switch-to|open-new-window)-application-(\d)$');
const cosmicSchema = 'cosmic.shortcuts';
const cosmicUserPrefix = 'cosmic-'; // Paths of the user's own commands in COSMIC.

final _whereRe = RegExp(
  // KDE: kde/<kglobalaccel component>:<action> (names with spaces, dots, colons in the action).
  r'^(?:(?:org\.gnome\.[a-z.-]{1,80}|cosmic\.shortcuts):[a-z0-9-]{1,80}|kde/[A-Za-z0-9._ -]{1,120}:[^\x00-\x1f\x7f]{1,160}|custom:' +
      RegExp.escape(customBase) +
      r'[A-Za-z0-9_-]{1,64}/)$',
);

String cleanWhere(Object? value) {
  final text = pyStr(value);
  return _whereRe.hasMatch(text) ? text : '';
}

bool _isArgv(Object? launch) => launch is List && launch.isNotEmpty && launch.every((a) => a is String);

/// load_state (gnome-launcher): {apps: {key: entry}, applied: [{where, accel}]}:
/// the shortcuts, and the accelerators taken from other bindings for them.
Map<String, dynamic> cleanGnomeState(Object? data) {
  final apps = data is Map ? data['apps'] : null;
  final clean = <String, dynamic>{};
  if (apps is Map) {
    for (final MapEntry(key: appId, value: entry) in apps.entries) {
      if (entry is! Map) continue;
      final shortcuts = <Combo>[];
      for (final item in entry['shortcuts'] is List ? entry['shortcuts'] as List : const []) {
        final combo = item is Map ? makeCombo(item['mods'] ?? const [], item['key'] ?? '') : null;
        if (combo == null) continue;
        combo['replaces'] = cut(item.containsKey('replaces') ? pyStrOf(item['replaces']) : '', 120);
        combo['taken_from'] = cleanWhere(item['taken_from']);
        final action = item.containsKey('action') ? pyStrOf(item['action']) : '';
        combo['action'] = actionIdRe.hasMatch(action) ? action : '';
        if ((combo['action'] as String).isNotEmpty && pyStr(item['label']).isNotEmpty) {
          combo['label'] = cut(pyStrOf(item['label']), 80);
        }
        shortcuts.add(combo);
      }
      final disabled = <Combo>[];
      for (final item in entry['disabled'] is List ? entry['disabled'] as List : const []) {
        final combo = item is Map ? makeCombo(item['mods'] ?? const [], item['key'] ?? '') : null;
        final where = item is Map ? cleanWhere(item['where']) : '';
        if (combo == null || where.isEmpty) continue;
        combo['description'] = cut(item.containsKey('description') ? pyStrOf(item['description']) : '', 120);
        combo['source'] = cut(item.containsKey('source') ? pyStrOf(item['source']) : '', 60);
        combo['where'] = where;
        disabled.add(combo);
      }
      final launch = entry['launch'];
      if ((shortcuts.isNotEmpty || disabled.isNotEmpty) && _isArgv(launch)) {
        clean['$appId'] = {
          'name': cut(entry.containsKey('name') ? pyStrOf(entry['name']) : '$appId', 120),
          'launch': [...launch as List],
          'shortcuts': shortcuts,
          'disabled': disabled,
        };
      }
    }
  }
  final applied = <Map<String, dynamic>>[];
  final raw = data is Map ? data['applied'] : null;
  for (final item in raw is List ? raw : const []) {
    if (item is Map && cleanWhere(item['where']).isNotEmpty && parseAccelerator(item['accel']) != null) {
      applied.add({'where': item['where'], 'accel': item['accel']});
    }
  }
  return {'apps': clean, 'applied': applied};
}

// --- GNOME's bindings ----------------------------------------------------------

/// What GNOME (or COSMIC) holds: GSettings through the `gsettings` program,
/// or COSMIC's shortcut file. The methods are gnome-launcher's GSettings.
abstract class KeySettings {
  Future<bool> available();

  /// [(schema id, key, summary, [accelerators])] for the desktop's own bindings.
  Future<List<(String, String, String, List<String>)>> bindingKeys();
  Future<List<String>> getStrv(String schema, String key);
  Future<void> setStrv(String schema, String key, List<String> values);
  Future<List<String>> customPaths();
  Future<void> setCustomPaths(List<String> paths);
  Future<Map<String, String>> readCustom(String path);
  Future<void> writeCustom(String path, Map<String, String> values);
  Future<void> resetCustom(String path);
  Future<void> sync();
}

/// read_desktop_binds: [{combo, description, where, accel, key_name}].
Future<List<Map<String, dynamic>>> readDesktopBinds(KeySettings settings) async => [
  for (final (schema, key, summary, accels) in await settings.bindingKeys())
    for (final accel in accels)
      if (parseAccelerator(accel) case final combo?)
        {'combo': combo, 'description': summary, 'where': '$schema:$key', 'accel': accel, 'key_name': key},
];

/// read_custom_binds: the user's own custom shortcuts (not the launcher's).
Future<List<Map<String, dynamic>>> readCustomBinds(KeySettings settings, String ownPrefix) async {
  final binds = <Map<String, dynamic>>[];
  for (final path in await settings.customPaths()) {
    if (!path.startsWith(customBase) || path.substring(customBase.length).startsWith(ownPrefix)) continue;
    final values = await settings.readCustom(path);
    final combo = parseAccelerator(values['binding']);
    if (combo != null) {
      final name = values['name'] ?? '';
      binds.add({
        'combo': combo,
        'description': name.isNotEmpty ? name : values['command'] ?? '',
        'command': values['command'] ?? '',
        'where': 'custom:$path',
        'accel': values['binding'],
      });
    }
  }
  return binds;
}

/// What the shortcut page asks of a desktop's bindings snapshot.
abstract interface class ShortcutBindings {
  (String, String) classify(Map combo, String appId, {Map? app, String action = ''});
  List<Map<String, dynamic>> externalShortcuts(Map app);
  List<Combo> suggestions(Map app, String appId, {List<String>? mods, int limit = 8});

  /// Where an assignment takes the key from ("" when nothing is taken).
  String takenFrom(Map combo);
}

/// Bindings (gnome-launcher): who owns which key combination right now.
final class GnomeBindings implements ShortcutBindings {
  GnomeBindings(
    this.state, {
    required List<Map<String, dynamic>> desktop,
    required List<Map<String, dynamic>> custom,
    this.favorites = const [],
    this.mainMods,
  }) {
    // Accelerators the launcher took away still belong to their owner for
    // the user: shown as taken by the launcher shortcut that has them.
    final taken = {for (final a in state['applied'] as List? ?? const []) '${a['where']}\x00${a['accel']}'};
    this.desktop = [for (final b in desktop) if (!taken.contains('${b['where']}\x00${b['accel']}')) b];
    this.custom = [for (final b in custom) if (!taken.contains('${b['where']}\x00${b['accel']}')) b];
  }

  final Map<String, dynamic> state;
  late final List<Map<String, dynamic>> desktop;
  late final List<Map<String, dynamic>> custom;
  final List<String> favorites;
  final List<String>? mainMods;

  Iterable<MapEntry<String, dynamic>> get _apps => (state['apps'] as Map<String, dynamic>).entries;

  (String?, Map?, Map?) _launcherOwner(Map combo) {
    final cid = comboId(combo);
    for (final MapEntry(key: id, value: entry) in _apps) {
      for (final sc in entry['shortcuts'] as List) {
        if (comboId(sc) == cid) return (id, entry, sc);
      }
    }
    return (null, null, null);
  }

  bool _disabledByLauncher(Map combo) {
    final cid = comboId(combo);
    return _apps.any((e) => (e.value['disabled'] as List).any((d) => comboId(d) == cid));
  }

  /// owner: (level, the other binding) for a key not bound by the launcher.
  (String, Map<String, dynamic>?) owner(Map combo) {
    final cid = comboId(combo);
    if (_disabledByLauncher(combo)) return (levelFree, null);
    for (final bind in custom) {
      if (comboId(bind['combo']) == cid) return (levelCustom, bind);
    }
    for (final bind in desktop) {
      if (comboId(bind['combo']) == cid) return (levelDesktop, bind);
    }
    return (levelFree, null);
  }

  /// classify: (level, description) for assigning combo to appId, opening
  /// the app itself or, with [action], one of its desktop actions.
  @override
  (String, String) classify(Map combo, String appId, {Map? app, String action = ''}) {
    final (ownerId, ownerEntry, shortcut) = _launcherOwner(combo);
    if (ownerId == appId) {
      final current = shortcut!['action'] as String? ?? '';
      return current == action ? (levelSame, ownerEntry!['name'] as String) : (levelRetarget, current);
    }
    if (ownerId != null) return (levelLauncher, ownerEntry!['name'] as String);
    if (app != null) {
      // Another binding already does exactly this: assigning would only duplicate it.
      for (final bind in externalShortcuts(app)) {
        if (comboId(bind['combo']) == comboId(combo)) {
          if (bind['action'] == action) return (levelSame, bind['description'] as String);
          break;
        }
      }
    }
    final (level, bind) = owner(combo);
    return (level, bind == null ? '' : bind['description'] as String);
  }

  /// taken_from: where an assignment takes the key from (its owner), or "".
  @override
  String takenFrom(Map combo) {
    final (level, bind) = owner(combo);
    return bind != null && (level == levelCustom || level == levelDesktop) ? bind['where'] as String : '';
  }

  /// used_letters: keys taken with the main modifiers (the default set).
  Set<String> usedLetters() {
    final mask = modmask(makeCombo(mainMods ?? defaultMods, 'A')!);
    return {
      for (final b in [...desktop, ...custom])
        if (modmask(b['combo']) == mask) (b['combo']['key'] as String).toLowerCase(),
      for (final e in _apps)
        for (final sc in e.value['shortcuts'] as List)
          if (modmask(sc) == mask) (sc['key'] as String).toLowerCase(),
    };
  }

  /// suggestions: free combos for this app, letters of its name first.
  @override
  List<Combo> suggestions(Map app, String appId, {List<String>? mods, int limit = 8}) =>
      suggestCombos(app, usedLetters(), (c) => classify(c, appId).$1, mods: mods, limit: limit);

  /// external_shortcuts: the user's own custom shortcuts whose command
  /// launches the app, and GNOME's Super + 1…9 (and Super + Ctrl + 1…9 for a
  /// new window) for an app pinned to the Dash.
  @override
  List<Map<String, dynamic>> externalShortcuts(Map app) {
    final desktopPath = app['desktop_path'] as String? ?? '';
    final desktopFile = p.basename(desktopPath);
    final desktopId = (desktopFile.endsWith('.desktop')
            ? desktopFile.substring(0, desktopFile.length - 8)
            : desktopFile)
        .toLowerCase();
    var program = '';
    try {
      final words = shlexSplit(app['exec'] as String? ?? '');
      if (words.isNotEmpty) program = p.basename(words.first).toLowerCase();
    } on ShlexError {
      program = '';
    }
    final result = <Map<String, dynamic>>[];
    for (final bind in custom) {
      List<String> argv;
      try {
        argv = shlexSplit(bind['command'] as String);
      } on ShlexError {
        continue;
      }
      if (argv.isEmpty) continue;
      final words = {for (final a in argv) _stripDesktop(p.basename(a).toLowerCase())};
      final first = p.basename(argv.first).toLowerCase();
      if (desktopPath.isNotEmpty && argv.contains(desktopPath) ||
          (desktopId.isNotEmpty && words.contains(desktopId)) ||
          (program.isNotEmpty &&
              first == program &&
              !const {'env', 'sh', 'bash', 'flatpak', 'python3', 'gio'}.contains(program))) {
        result.add({...bind, 'file': 'Custom', 'action': ''});
      }
    }
    if (desktopFile.isNotEmpty && favorites.contains(desktopFile)) {
      final position = favorites.indexOf(desktopFile) + 1;
      final dash = [
        for (final bind in desktop)
          if (favoriteKey.firstMatch(bind['key_name'] as String? ?? '') case final m?
              when int.parse(m[1]!) == position)
            bind,
      ];
      // Switching to the app first (Super + 1), then its new window (Super + Ctrl + 1).
      mergeSortBy(dash, (b) => (b['key_name'] as String).startsWith('switch-to') ? 0 : 1);
      result.addAll([for (final b in dash) {...b, 'file': 'GNOME', 'action': ''}]);
    }
    return result;
  }
}

String _stripDesktop(String name) => name.endsWith('.desktop') ? name.substring(0, name.length - 8) : name;

/// A stable sort (Python's sorted keeps equal items in order).
void mergeSortBy<T>(List<T> list, Comparable Function(T) key) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = key(a.$2).compareTo(key(b.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < indexed.length; i++) {
    list[i] = indexed[i].$2;
  }
}

/// Bindings.suggestions of both references: free combos, the app's name
/// letters first; with [mods] only that set (sorted by key), else the first
/// free letter of each common Super-based set.
List<Combo> suggestCombos(
  Map app,
  Set<String> used,
  String Function(Combo) level, {
  List<String>? mods,
  int limit = 8,
}) {
  final name = '${app['name'] ?? ''}'.replaceAll(RegExp('[^A-Za-z0-9]'), '').toUpperCase();
  final nameLetters = <String>[];
  for (final c in name.split('')) {
    if (RegExp('[A-Z]').hasMatch(c) && !nameLetters.contains(c)) nameLetters.add(c);
  }
  final keys = [
    ...nameLetters,
    for (final c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) if (!nameLetters.contains(c)) c,
  ].where((k) => !used.contains(k.toLowerCase())).toList();
  if (mods != null && mods.isNotEmpty) {
    final found = <Combo>[];
    for (final key in keys) {
      final combo = makeCombo(mods, key);
      if (combo != null && level(combo) == levelFree) {
        found.add(combo);
        if (found.length >= limit) break;
      }
    }
    return found..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
  }
  final found = <Combo>[];
  for (final set in const [
    ['SUPER', 'ALT'], ['SUPER', 'CTRL'], ['SUPER', 'CTRL', 'ALT'], ['SUPER', 'SHIFT', 'ALT'], ['SUPER', 'SHIFT', 'CTRL'],
  ]) {
    found.addAll(suggestCombos(app, used, level, mods: set, limit: 1));
    if (found.length >= limit) break;
  }
  return found;
}

// --- GNOME writing ---------------------------------------------------------------

/// Whether a `where` (a binding's place, as kept in shortcuts.json) belongs to
/// the desktop of [kind] ('kde', 'cosmic' or 'gnome'): `custom:` paths are
/// checked against the desktop's own list before use, so they count for all.
bool whereBelongsTo(String kind, String where) {
  if (where.startsWith('custom:')) return true;
  return switch (kind) {
    'kde' => where.startsWith('kde/'),
    'cosmic' => where.startsWith('$cosmicSchema:'),
    _ => where.startsWith('org.gnome.'),
  };
}

/// _desired_removals: {(where, accel)} the launcher keeps taken from others.
Set<(String, String)> desiredRemovals(Map state) => {
  for (final entry in (state['apps'] as Map).values) ...{
    for (final combo in entry['shortcuts'] as List)
      if ((combo['taken_from'] as String? ?? '').isNotEmpty) (combo['taken_from'] as String, accelerator(combo)),
    for (final combo in entry['disabled'] as List) (combo['where'] as String, accelerator(combo)),
  },
};

bool sameAccel(Object? a, Object? b) {
  final first = parseAccelerator(a), second = parseAccelerator(b);
  return first != null && second != null && comboId(first) == comboId(second);
}

/// _take: remove accel from the binding at where; true when it was there.
Future<bool> takeKey(KeySettings settings, String where, String accel, {void Function()? beforeChange}) async {
  if (where.startsWith('custom:')) {
    final path = where.substring(7);
    if (!(await settings.customPaths()).contains(path)) return false;
    if (!sameAccel((await settings.readCustom(path))['binding'], accel)) return false;
    beforeChange?.call();
    await settings.writeCustom(path, {'binding': ''});
    return true;
  }
  final i = where.indexOf(':');
  final schema = where.substring(0, i), key = where.substring(i + 1);
  final current = await settings.getStrv(schema, key);
  final kept = [for (final a in current) if (!sameAccel(a, accel)) a];
  if (kept.length == current.length) return false;
  beforeChange?.call();
  await settings.setStrv(schema, key, kept);
  return true;
}

/// _give_back: put accel back on the binding at where (unless it got another key since).
Future<void> giveBack(KeySettings settings, String where, String accel, {void Function()? beforeChange}) async {
  if (where.startsWith('custom:')) {
    final path = where.substring(7);
    if ((await settings.customPaths()).contains(path) && ((await settings.readCustom(path))['binding'] ?? '').isEmpty) {
      beforeChange?.call();
      await settings.writeCustom(path, {'binding': accel});
    }
    return;
  }
  final i = where.indexOf(':');
  final schema = where.substring(0, i), key = where.substring(i + 1);
  final current = [for (final a in await settings.getStrv(schema, key)) if (a.isNotEmpty) a];
  if (!current.any((a) => sameAccel(a, accel))) {
    beforeChange?.call();
    await settings.setStrv(schema, key, [...current, accel]);
  }
}

/// The keys other bindings hold that a launcher shortcut of [state] uses,
/// as {(where, the launcher's accel)}: those bound now, and those taken that
/// way before ([previous]) while a launcher shortcut still uses their key.
/// A shortcut only records the binding it took when it was made
/// (`taken_from`); the desktop can bind its key again later (KDE did, for
/// "Walk through activities (Reverse)" on Super+Shift+A), and a state moved
/// from another desktop names bindings that are not there. KDE then drops
/// the launcher's key without an error.
Future<Set<(String, String)>> conflictingKeys(
  Map state,
  KeySettings settings, {
  required Set<(String, String)> previous,
  required String ownPrefix,
}) async {
  final accels = [
    for (final entry in (state['apps'] as Map).values)
      for (final combo in entry['shortcuts'] as List) accelerator(combo),
  ];
  return {
    for (final bind in [...await readDesktopBinds(settings), ...await readCustomBinds(settings, ownPrefix)])
      for (final accel in accels)
        if (sameAccel(accel, bind['accel'])) (bind['where'] as String, accel),
    for (final item in previous)
      if (accels.any((accel) => sameAccel(accel, item.$2))) item,
  };
}

/// The custom path for each of [desired] (in order) that keeps every
/// shortcut on the path it had ([existing]: path to its values now): one
/// with the same command keeps its path, new ones take the lowest free
/// numbers. On KDE a path's number is part of the component's name, so
/// numbering by position renamed every later component when one shortcut
/// was added, and re-registering them all at once crashed KWin (2026-11-08).
List<String> stableSlotPaths(
  List<Map<String, String>> desired,
  Map<String, Map<String, String>> existing,
  String ownPrefix,
) {
  final free = {...existing.keys};
  final slots = List<String?>.filled(desired.length, null);
  // Same command and key first, then the same command alone.
  for (final exact in [true, false]) {
    for (var i = 0; i < desired.length; i++) {
      if (slots[i] != null) continue;
      final match = free
          .where((path) =>
              existing[path]!['command'] == desired[i]['command'] &&
              (!exact || sameAccel(existing[path]!['binding'], desired[i]['binding'])))
          .toList()
        ..sort();
      if (match.isNotEmpty) {
        slots[i] = match.first;
        free.remove(match.first);
      }
    }
  }
  final taken = {...slots.whereType<String>(), ...free};
  var n = 0;
  for (var i = 0; i < desired.length; i++) {
    if (slots[i] != null) continue;
    while (taken.contains('$customBase$ownPrefix$n/')) {
      n++;
    }
    slots[i] = '$customBase$ownPrefix$n/';
    taken.add(slots[i]!);
  }
  return slots.cast<String>();
}

/// save_and_apply (gnome-launcher), without the state file: write the
/// launcher's custom keybindings at [ownPrefix]N/, take or give back the keys
/// of other bindings. Returns the state to save, with `applied`.
/// [command] is the command line of one shortcut (shortcut_command).
/// With [takeConflicts], every other binding on a launcher key is taken too
/// ([conflictingKeys]) and given back when the launcher no longer uses it.
Future<Map<String, dynamic>> applyGnome(
  Map<String, dynamic> state,
  KeySettings settings, {
  required List<Map> previousApplied,
  required String ownPrefix,
  required String Function(List<String> launch, String action) command,
  void Function()? beforeChange,
  bool takeConflicts = false,
  bool stableSlots = false,
  bool Function(String where)? owns,
}) async {
  var checked = false;
  void check() {
    if (!checked) { beforeChange?.call(); checked = true; }
  }
  // One shortcuts.json serves every desktop of a shared home: a key taken on
  // COSMIC (cosmic.shortcuts:…) means nothing to KDE's kglobalaccel and the
  // reverse. Bindings of another desktop are never taken or given back here;
  // the record of them is kept for when that desktop saves again.
  final mine = owns ?? (_) => true;
  final foreign = [
    for (final a in previousApplied)
      if (!mine('${a['where']}')) {'where': '${a['where']}', 'accel': '${a['accel']}'},
  ];
  final previous = {
    for (final a in previousApplied)
      if (mine('${a['where']}')) ('${a['where']}', '${a['accel']}'),
  };
  final wanted = {for (final item in desiredRemovals(state)) if (mine(item.$1)) item};
  if (takeConflicts) {
    wanted.addAll(await conflictingKeys(state, settings, previous: previous, ownPrefix: ownPrefix));
  }
  final applied = <Map<String, dynamic>>[];
  int order((String, String) a, (String, String) b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  }

  for (final (where, accel) in (previous.difference(wanted).toList()..sort(order))) {
    await giveBack(settings, where, accel, beforeChange: check);
  }
  for (final item in (wanted.toList()..sort(order))) {
    // With [takeConflicts] a key taken before is taken again when the
    // desktop bound it again since (KDE does).
    final known = previous.contains(item) && !takeConflicts;
    if (known || await takeKey(settings, item.$1, item.$2, beforeChange: check) || previous.contains(item)) {
      applied.add({'where': item.$1, 'accel': item.$2});
    }
  }
  bool own(String path) => path.startsWith(customBase) && path.substring(customBase.length).startsWith(ownPrefix);
  final all = await settings.customPaths();
  final paths = [for (final path in all) if (!own(path)) path];
  final oldOwn = [for (final path in all) if (own(path)) path];
  final written = <String>[];
  final apps = state['apps'] as Map<String, dynamic>;
  final keys = apps.keys.toList();
  mergeSortBy(keys, (k) => (apps[k]['name'] as String).toLowerCase());
  final desired = <Map<String, String>>[
    for (final k in keys)
      for (final combo in (apps[k] as Map)['shortcuts'] as List)
        () {
          final entry = apps[k] as Map;
          final action = combo['action'] as String? ?? '';
          final label = combo['label'] as String? ?? '';
          final what = action.isNotEmpty ? '${entry['name']}: ${label.isNotEmpty ? label : action}' : entry['name'] as String;
          return {
            'name': cut(what, 120),
            'command': command([for (final a in entry['launch'] as List) '$a'], action),
            'binding': accelerator(combo),
          };
        }(),
  ];
  if (!stableSlots) {
    for (final values in desired) {
      final path = '$customBase$ownPrefix${written.length}/';
      check();
      await settings.writeCustom(path, values);
      written.add(path);
    }
    for (final stale in oldOwn) {
      if (!written.contains(stale)) { check(); await settings.resetCustom(stale); }
    }
  } else {
    final slots = stableSlotPaths(desired, {for (final path in oldOwn) path: await settings.readCustom(path)}, ownPrefix);
    // Stale ones go first: one of them may still hold a key a new one wants.
    for (final stale in oldOwn) {
      if (!slots.contains(stale)) { check(); await settings.resetCustom(stale); }
    }
    for (var i = 0; i < desired.length; i++) {
      final current = oldOwn.contains(slots[i]) ? await settings.readCustom(slots[i]) : null;
      final same = current != null &&
          current['name'] == desired[i]['name'] &&
          current['command'] == desired[i]['command'] &&
          sameAccel(current['binding'], desired[i]['binding']);
      if (!same) { check(); await settings.writeCustom(slots[i], desired[i]); }
      written.add(slots[i]);
    }
  }
  check();
  await settings.setCustomPaths([...paths, ...written]);
  await settings.sync();
  return {...state, 'applied': [...applied, ...foreign]};
}

// --- GNOME through the gsettings program ----------------------------------------

/// GVariant text of a string ('…', as gsettings prints and reads it).
String gvariantString(String value) {
  final out = StringBuffer("'");
  for (final c in value.runes) {
    final ch = String.fromCharCode(c);
    if (ch == r'\' || ch == "'") {
      out.write('\\$ch');
    } else if (c < 32 || c == 127) {
      out.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.write(ch);
    }
  }
  return (out..write("'")).toString();
}

String gvariantStrv(List<String> values) => '[${values.map(gvariantString).join(', ')}]';

/// The strings of a GVariant text value: one string ('…' or "…") or an
/// array of strings (`['a', "b"]`, `@as []`). Null for anything else.
List<String>? parseGVariantStrings(String text, {bool array = true}) {
  var s = text.trim();
  if (array) {
    if (s.startsWith('@as ')) s = s.substring(4).trim();
    if (!s.startsWith('[') || !s.endsWith(']')) return null;
    s = s.substring(1, s.length - 1);
  }
  final out = <String>[];
  var i = 0;
  void blanks() {
    while (i < s.length && ' \t\n'.contains(s[i])) {
      i++;
    }
  }

  blanks();
  while (i < s.length) {
    final quote = s[i];
    if (quote != "'" && quote != '"') return null;
    i++;
    final word = StringBuffer();
    var closed = false;
    while (i < s.length) {
      final c = s[i];
      if (c == quote) {
        closed = true;
        i++;
        break;
      }
      if (c == r'\' && i + 1 < s.length) {
        final n = s[i + 1];
        if (n == 'u' && i + 6 <= s.length) {
          final code = int.tryParse(s.substring(i + 2, i + 6), radix: 16);
          if (code == null) return null;
          word.writeCharCode(code);
          i += 6;
          continue;
        }
        word.write(switch (n) { 'n' => '\n', 't' => '\t', _ => n });
        i += 2;
        continue;
      }
      word.write(c);
      i++;
    }
    if (!closed) return null;
    out.add(word.toString());
    blanks();
    if (!array) return i == s.length ? out : null;
    if (i < s.length) {
      if (s[i] != ',') return null;
      i++;
      blanks();
    }
  }
  return array ? out : null;
}

/// gnome-launcher's GSettings on the `gsettings` program: argv only, each
/// call bounded (output and time). [run] returns stdout or null on failure.
final class GSettingsProgram implements KeySettings {
  GSettingsProgram(this.run);
  final Future<String?> Function(List<String> args) run;

  Future<String> _must(List<String> args) async {
    final out = await run(args);
    if (out == null) throw const FileSystemException('gsettings failed');
    return out;
  }

  @override
  Future<bool> available() async {
    final out = await run(['list-relocatable-schemas']);
    return out != null && const LineSplitter().convert(out).map((l) => l.trim()).contains(customSchema);
  }

  /// `gsettings list-recursively` lines: (schema, key, value text).
  Future<List<(String, String, String)>> _list(String schema) async {
    final out = await run(['list-recursively', schema]) ?? '';
    return [
      for (final line in const LineSplitter().convert(out))
        if (RegExp(r'^(\S+) (\S+) (.*)$').firstMatch(line) case final m?) (m[1]!, m[2]!, m[3]!),
    ];
  }

  /// GNOME's own bindings: every string-list key of the binding schemas.
  /// The summary is the key name in words (the program shows no summaries;
  /// GNOME's schemas mostly say the same: "Switch to application 1").
  @override
  Future<List<(String, String, String, List<String>)>> bindingKeys() async {
    final installed = const LineSplitter().convert(await run(['list-schemas']) ?? '').map((l) => l.trim()).toSet();
    final found = <(String, String, String, List<String>)>[];
    for (final schema in bindingSchemas) {
      if (!installed.contains(schema)) continue;
      for (final (_, key, value) in await _list(schema)) {
        final accels = parseGVariantStrings(value);
        if (accels == null || key == customListKey) continue;
        found.add((schema, key, keySummary(key), [for (final a in accels) if (a.isNotEmpty) a]));
      }
    }
    return found;
  }

  static String keySummary(String key) {
    final words = key.replaceAll('-', ' ');
    return words.isEmpty ? key : words[0].toUpperCase() + words.substring(1);
  }

  @override
  Future<List<String>> getStrv(String schema, String key) async =>
      parseGVariantStrings(await _must(['get', schema, key])) ?? const [];

  @override
  Future<void> setStrv(String schema, String key, List<String> values) =>
      _must(['set', schema, key, gvariantStrv(values)]);

  @override
  Future<List<String>> customPaths() => getStrv(mediaKeys, customListKey);

  @override
  Future<void> setCustomPaths(List<String> paths) => setStrv(mediaKeys, customListKey, paths);

  @override
  Future<Map<String, String>> readCustom(String path) async {
    final values = <String, String>{'name': '', 'command': '', 'binding': ''};
    for (final (_, key, value) in await _list('$customSchema:$path')) {
      if (values.containsKey(key)) values[key] = parseGVariantStrings(value, array: false)?.first ?? '';
    }
    return values;
  }

  @override
  Future<void> writeCustom(String path, Map<String, String> values) async {
    for (final MapEntry(:key, :value) in values.entries) {
      await _must(['set', '$customSchema:$path', key, gvariantString(value)]);
    }
  }

  @override
  Future<void> resetCustom(String path) async {
    for (final key in const ['name', 'command', 'binding']) {
      await _must(['reset', '$customSchema:$path', key]);
    }
  }

  @override
  Future<void> sync() async {} // Each gsettings call has written already.
}

// --- COSMIC's shortcut file ---------------------------------------------------------

/// _ron_skip: the index after any whitespace and comments.
int ronSkip(String text, int index) {
  while (index < text.length) {
    if (RegExp(r'\s').hasMatch(text[index])) {
      index++;
    } else if (text.startsWith('//', index)) {
      final end = text.indexOf('\n', index);
      index = end < 0 ? text.length : end + 1;
    } else if (text.startsWith('/*', index)) {
      final end = text.indexOf('*/', index);
      if (end < 0) throw const FormatException('unterminated comment');
      index = end + 2;
    } else {
      break;
    }
  }
  return index;
}

/// _ron_find: the index of the first stop character outside strings and brackets.
int ronFind(String text, int index, String stops) {
  var depth = 0;
  while (index < text.length) {
    final char = text[index];
    if (char == '"' || char == "'") {
      index++;
      while (index < text.length && text[index] != char) {
        index += text[index] == r'\' ? 2 : 1;
      }
      if (index >= text.length) throw const FormatException('unterminated string');
    } else if (text.startsWith('//', index) || text.startsWith('/*', index)) {
      index = ronSkip(text, index);
      continue;
    } else if (depth == 0 && stops.contains(char)) {
      return index;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      depth--;
    }
    index++;
  }
  throw const FormatException('unterminated map');
}

String ronQuote(String text) => '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
String ronUnquote(String text) => text.replaceAllMapped(RegExp(r'\\(.)', dotAll: false), (m) => m[1]!);

/// _cosmic_entry: a map entry of a shortcut file, read; the text stays as it was.
Map<String, dynamic> cosmicEntry(String gap, String raw) {
  final colon = ronFind(raw, 0, ':');
  final binding = raw.substring(0, colon), action = raw.substring(colon + 1).trim();
  final mods = RegExp(r'modifiers:\s*\[([^\]]*)\]').firstMatch(binding);
  final key = RegExp(r'key:\s*"((?:[^"\\]|\\.)*)"').firstMatch(binding);
  final description = RegExp(r'description:\s*Some\(\s*"((?:[^"\\]|\\.)*)"').firstMatch(binding);
  Combo? combo;
  if (mods != null && key != null) {
    final names = {for (final m in RegExp('[A-Za-z]+').allMatches(mods[1]!)) m[0]!.toUpperCase()};
    combo = makeCombo(names.toList(), ronUnquote(key[1]!));
  }
  return {
    'gap': gap,
    'raw': raw,
    'combo': combo,
    'action': action,
    'description': description != null ? ronUnquote(description[1]!) : '',
  };
}

/// parse_cosmic_shortcuts: (text before the entries, entries, text after).
/// Throws FormatException when it is not one: such a file is never rewritten.
(String, List<Map<String, dynamic>>, String) parseCosmicShortcuts(String text) {
  final start = ronSkip(text, 0);
  if (!text.startsWith('{', start)) throw const FormatException('not a map');
  final headEnd = start + 1;
  var position = headEnd;
  final entries = <Map<String, dynamic>>[];
  while (true) {
    final begin = ronSkip(text, position);
    if (begin >= text.length) throw const FormatException('unterminated map');
    if (text[begin] == '}') return (text.substring(0, headEnd), entries, text.substring(position));
    final end = ronFind(text, ronFind(text, begin, ':') + 1, ',}');
    final raw = text.substring(begin, end).trimRight();
    entries.add(cosmicEntry(text.substring(position, begin), raw));
    position = begin + raw.length;
    position = ronSkip(text, position);
    if (text.startsWith(',', position)) {
      position++;
    } else {
      position = begin + raw.length;
    }
  }
}

String cosmicSlug(Map combo) => [
  for (final m in combo['mods'] as List) (m as String).toLowerCase(),
  (combo['key'] as String).toLowerCase().replaceAll('_', '-'),
].join('-');

/// _cosmic_action_label: "System(Terminal)" → "Terminal", "Focus(Left)" → "Focus Left".
String cosmicActionLabel(String action) {
  final inner = RegExp(r'^System\((.*)\)$').firstMatch(action);
  final text = inner != null ? inner[1]! : action;
  final words = text.replaceAll(RegExp('[()]'), ' ').replaceAll(RegExp('(?<=[a-z])(?=[A-Z])'), ' ');
  return words.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
}

/// CosmicSettings (gnome-launcher): COSMIC's shortcuts behind the methods of
/// KeySettings: its defaults plus the user's `custom` file, which overrides
/// them. A key is taken by a `Disable` entry (an entry of the user's own is
/// kept in the taken file and comes back with the key). The launcher's
/// entries (description ending in [ownTag]) are rewritten by sync(), in one
/// atomic write: COSMIC reloads the file when it changes.
final class CosmicSettings implements KeySettings {
  CosmicSettings({
    required this.customFile,
    required this.defaultsFile,
    required this.readTaken,
    required this.writeTaken,
    required this.writeText,
    this.ownTag = ' (Maprisma Launcher)',
    this.ownPrefix = 'maprisma-launcher-',
  }) {
    _load();
  }

  final String customFile, defaultsFile, ownTag, ownPrefix;
  final Object? Function() readTaken;
  final void Function(Object data) writeTaken;
  final void Function(String path, String text) writeText;

  bool dirty = false;
  late String head, tail, original;
  late List<Map<String, dynamic>> entries;
  late Map<String, String> taken, shadowed;
  late Map<String, Map<String, String>> own;

  /// Missing: null. Anything else must be a regular file of at most 1 MiB
  /// (read non-blocking, so a FIFO cannot hang the core), else it throws:
  /// a file we cannot read is never overwritten.
  static String? _read(String path) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) return null;
    final bytes = Posix.instance.readRegular(path, 1024 * 1024);
    if (bytes == null) throw const FormatException('not a regular file of at most 1 MiB');
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _load() {
    final text = _read(customFile) ?? '{\n}\n';
    final (h, e, t) = parseCosmicShortcuts(text);
    head = h;
    entries = e;
    tail = t;
    original = text;
    final data = readTaken();
    final stored = data is Map ? data : const {};
    Map<String, String> strings(Object? v) =>
        v is Map ? {for (final e in v.entries) pyStrOf(e.key): pyStrOf(e.value)} : {};
    // taken: entries given up on request; shadowed: entries an own shortcut replaced.
    taken = strings(stored['taken']);
    shadowed = strings(stored['shadowed']);
    own = {};
    for (final entry in entries) {
      if (_isOwn(entry)) {
        final description = entry['description'] as String;
        own['$customBase$ownPrefix${own.length}/'] = {
          'name': description.endsWith(ownTag) ? description.substring(0, description.length - ownTag.length) : description,
          'command': spawned(entry) ?? '',
          'binding': accelerator(entry['combo']),
        };
      }
    }
  }

  void _refresh() {
    if (!dirty) _load();
  }

  bool _isOwn(Map entry) => entry['combo'] != null && (entry['description'] as String).endsWith(ownTag);

  static String? spawned(Map entry) {
    final m = RegExp(r'^Spawn\(\s*"((?:[^"\\]|\\.)*)"').firstMatch(entry['action'] as String);
    return m == null ? null : ronUnquote(m[1]!);
  }

  Map<String, dynamic>? _find(String slug) => entries
      .where((e) => e['combo'] != null && cosmicSlug(e['combo']) == slug && !_isOwn(e))
      .firstOrNull;

  void _remove(Map<String, dynamic> entry) {
    final index = entries.indexOf(entry);
    entries.removeAt(index);
    final gap = entry['gap'] as String;
    if (gap.trim().isNotEmpty) {
      // A comment stays where it was.
      if (index < entries.length) {
        entries[index]['gap'] = gap + (entries[index]['gap'] as String);
      } else {
        tail = gap + tail;
      }
    }
  }

  void _add(String raw) => entries.add(cosmicEntry('\n    ', raw));

  static String bindingText(Map combo, [String description = '']) {
    final names = [for (final m in combo['mods'] as List) modLabels[m]!].join(', ');
    final key = combo['key'] as String;
    final extra = description.isNotEmpty ? ', description: Some(${ronQuote(description)})' : '';
    return '(modifiers: [$names], key: ${ronQuote(key.length == 1 ? key.toLowerCase() : key)}$extra)';
  }

  /// _effective: {slug: (combo, action)} that COSMIC's defaults and the
  /// user's file bind right now, without commands and the launcher's keys.
  Map<String, (Combo, String)> effective() {
    final (_, defaults, _) = parseCosmicShortcuts(_read(defaultsFile) ?? (throw const FileSystemException('no defaults')));
    final found = {
      for (final e in defaults)
        if (e['combo'] != null) cosmicSlug(e['combo']): (e['combo'] as Combo, e['action'] as String),
    };
    for (final entry in entries) {
      if (entry['combo'] == null) continue;
      final slug = cosmicSlug(entry['combo']);
      if (_isOwn(entry) || entry['action'] == 'Disable' || spawned(entry) != null) {
        found.remove(slug);
      } else {
        found[slug] = (entry['combo'] as Combo, entry['action'] as String);
      }
    }
    return found;
  }

  @override
  Future<bool> available() async => File(defaultsFile).existsSync();

  @override
  Future<List<(String, String, String, List<String>)>> bindingKeys() async {
    _refresh();
    return [
      for (final MapEntry(key: slug, value: (combo, action)) in effective().entries)
        (cosmicSchema, slug, cosmicActionLabel(action), [accelerator(combo)]),
    ];
  }

  @override
  Future<List<String>> getStrv(String schema, String key) async {
    final found = effective()[key];
    return found == null ? [] : [accelerator(found.$1)];
  }

  @override
  Future<void> setStrv(String schema, String key, List<String> values) async {
    dirty = true;
    final entry = _find(key);
    if (values.isNotEmpty) {
      if (entry != null && entry['action'] == 'Disable') _remove(entry);
      final raw = taken.remove(key) ?? '';
      if (raw.isNotEmpty) _add(raw);
      return;
    }
    final combo = entry != null ? entry['combo'] as Map : effective()[key]!.$1;
    if (entry != null) {
      taken[key] = entry['raw'] as String;
      _remove(entry);
    } else {
      taken[key] = '';
    }
    _add('${bindingText(combo)}: Disable');
  }

  String _userPath(String slug) => '$customBase$cosmicUserPrefix$slug/';

  @override
  Future<List<String>> customPaths() async {
    _refresh();
    return [
      ...own.keys,
      for (final entry in entries)
        if (entry['combo'] != null && !_isOwn(entry) && spawned(entry) != null) _userPath(cosmicSlug(entry['combo'])),
      for (final MapEntry(key: slug, value: raw) in taken.entries)
        if (raw.isNotEmpty && spawned(cosmicEntry('', raw)) != null) _userPath(slug),
    ];
  }

  @override
  Future<void> setCustomPaths(List<String> paths) async {
    dirty = true;
    own.removeWhere((path, _) => !paths.contains(path));
  }

  @override
  Future<Map<String, String>> readCustom(String path) async {
    if (own[path] case final values?) return {...values};
    final slug = path.substring(customBase.length + cosmicUserPrefix.length, path.length - 1);
    var entry = _find(slug);
    final isTaken = entry == null || spawned(entry) == null;
    if (isTaken) {
      final raw = taken[slug] ?? '';
      entry = cosmicEntry('', raw.isNotEmpty ? raw : '(modifiers: []): Disable');
    }
    return {
      'name': entry['description'] as String,
      'command': spawned(entry) ?? '',
      'binding': isTaken ? '' : accelerator(entry['combo']),
    };
  }

  @override
  Future<void> writeCustom(String path, Map<String, String> values) async {
    dirty = true;
    if (path.startsWith(customBase + ownPrefix)) {
      own.putIfAbsent(path, () => {}).addAll(values);
    } else {
      final binding = values['binding'] ?? '';
      await setStrv(
        cosmicSchema,
        path.substring(customBase.length + cosmicUserPrefix.length, path.length - 1),
        binding.isNotEmpty ? [binding] : [],
      );
    }
  }

  @override
  Future<void> resetCustom(String path) async {
    dirty = true;
    own.remove(path);
  }

  /// The file's text as sync() writes it (also for the oracle tests).
  String render() {
    for (final entry in [for (final e in entries) if (_isOwn(e)) e]) {
      _remove(entry);
    }
    final wanted = <String, (Combo, Map<String, String>)>{};
    for (final values in own.values) {
      final combo = parseAccelerator(values['binding']);
      if (combo != null) wanted[cosmicSlug(combo)] = (combo, values);
    }
    for (final MapEntry(key: slug, value: (combo, values)) in wanted.entries) {
      // The launcher's entry replaces any other on the key (one entry per key).
      final entry = _find(slug);
      if (entry != null) {
        if (!taken.containsKey(slug)) shadowed[slug] = entry['raw'] as String;
        _remove(entry);
      }
      _add('${bindingText(combo, (values['name'] ?? '') + ownTag)}: Spawn(${ronQuote(values['command'] ?? '')})');
    }
    for (final slug in [for (final s in shadowed.keys) if (!wanted.containsKey(s)) s]) {
      _add(shadowed.remove(slug)!);
    }
    final text = head + entries.map((e) => '${e['gap']}${e['raw']},').join() + tail;
    parseCosmicShortcuts(text); // Never hand COSMIC a file that cannot be read back.
    return text;
  }

  @override
  Future<void> sync() async {
    final text = render();
    writeTaken({'taken': taken, 'shadowed': shadowed});
    if (text != original) writeText(customFile, text);
    dirty = false;
    _load();
  }
}
