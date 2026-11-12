/// App Manager's own files in ~/.config/maprisma-launcher: read bounded, written
/// atomically and privately (0600, never through a symlink). The first start
/// copies them from the old apps (never moves them).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';
import 'posix.dart';

const maxConfigBytes = 256 * 1024;

final class ConfigStore {
  ConfigStore(this.session, {String? dir})
    : dir = dir ?? p.join(_configHome(session), 'maprisma-launcher');
  final Session session;
  final String dir;

  static String _configHome(Session session) =>
      session.environment['XDG_CONFIG_HOME']?.isNotEmpty == true
      ? session.environment['XDG_CONFIG_HOME']!
      : p.join(session.home, '.config');

  String path(String name) => p.join(dir, name);

  /// The JSON in [name], or null when missing, too large or not JSON.
  Object? readJson(String name, {int cap = maxConfigBytes}) =>
      readJsonFile(path(name), cap: cap);

  static Object? readJsonFile(String file, {int cap = maxConfigBytes}) {
    final bytes = Posix.instance.readRegular(file, cap, follow: false);
    if (bytes == null) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
  }

  /// Write [data] as JSON: a private temporary file next to it, flushed, then
  /// renamed over the old one (a symlink there is replaced, never followed).
  void writeJson(String name, Object? data) {
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync(recursive: true);
      Process.runSync('chmod', ['700', dir]);
    }
    final target = path(name);
    final tmp = File(p.join(dir, '.$name.$pid.tmp'));
    // A leftover (or a link someone put there) goes; the link is never followed.
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Nothing there.
    }
    final text = const JsonEncoder.withIndent('  ').convert(data);
    if (!Posix.instance.writeNewPrivate(tmp.path, utf8.encode(text))) {
      if (tmp.existsSync()) tmp.deleteSync();
      throw FileSystemException('Could not write', target);
    }
    try {
      tmp.renameSync(target);
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }

  /// First start: copy groups, hidden entries and settings from the newer of
  /// the old apps' folders (gnome-launcher, the Omarchy plugin). Returns
  /// what was copied from where; nothing when App Manager has files already.
  Map<String, dynamic> importOldConfig() {
    const names = ['groups.json', 'hidden.json', 'settings.json', 'icons.json', 'seen.json'];
    if (names.any((n) => File(path(n)).existsSync())) return {};
    final home = _configHome(session);
    String? source;
    var newest = -1;
    for (final old in ['gnome-launcher', 'applauncher']) {
      final groups = File(p.join(home, old, 'groups.json'));
      final settings = File(p.join(home, old, 'settings.json'));
      final stamp = [groups, settings]
          .where((f) => f.existsSync())
          .map((f) => f.lastModifiedSync().millisecondsSinceEpoch)
          .fold(-1, (a, b) => a > b ? a : b);
      if (stamp > newest) {
        newest = stamp;
        source = p.join(home, old);
      }
    }
    if (source == null) return {};
    final copied = <String>[];
    for (final name in names) {
      final data = readJsonFile(p.join(source, name));
      if (data == null) continue;
      // The Omarchy plugin's groups also hold its plugin page: apps only.
      writeJson(
        name,
        name == 'groups.json' && data is Map ? {'apps': data['apps']} : data,
      );
      copied.add(name);
    }
    final result = {'from': source, 'copied': copied};
    if (copied.isNotEmpty) writeJson('imported.json', result);
    return result;
  }
}

// --- settings.json ---------------------------------------------------------------

const wideLayouts = ['folders', 'cards', 'icons', 'cube'];
const languageCodes = ['en', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'pl'];
const managerIds = ['pacman', 'aur', 'flatpak', 'snap', 'apt', 'dnf', 'zypper'];
const iconSizeChoices = {
  'list': [20, 24, 28, 32, 36, 44, 52],
  'cards': [32, 40, 44, 48, 56, 64],
  'folders': [50, 60, 70, 80, 90, 100],
  'icons': [48, 56, 64, 72, 88, 96, 112, 128],
};
/// The header's buttons, in their default order (the user can drag them).
const headerButtons = ['running', 'marks', 'hidden', 'reload', 'ask', 'plugins', 'settings'];

/// A saved order: the known buttons once each, the missing ones after them
/// in their default order (a new button appears at its default place last).
List<String> headerOrder(Object? value) {
  final order = <String>[];
  if (value is List) {
    for (final id in value) {
      if (id is String && headerButtons.contains(id) && !order.contains(id)) order.add(id);
    }
  }
  return [...order, for (final id in headerButtons) if (!order.contains(id)) id];
}

const defaultIconSizes = {'list': 32, 'cards': 44, 'folders': 100, 'icons': 72};

/// The settings the app uses, each checked as launcher_core reads it.
final class Settings {
  Settings(this.store);
  final ConfigStore store;

  Map<String, dynamic> raw() {
    final data = store.readJson('settings.json', cap: 64 * 1024);
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  Map<String, dynamic> read() {
    final data = raw();
    final view = data['view'];
    final wide = data['wide_layout'];
    final shown = data['shown_layouts'];
    final corners = data['corners'];
    return {
      'view': view == 'groups' || view == 'origin' ? view : 'list',
      'wide_layout': wideLayouts.contains(wide) ? wide : 'folders',
      'shown_layouts': shown is List
          ? (() {
              final chosen = wideLayouts.where(shown.contains).toList();
              return chosen.isEmpty ? [...wideLayouts] : chosen;
            })()
          : [...wideLayouts],
      'corners': const ['windows', 'slight', 'rounded', 'square'].contains(corners)
          ? corners
          : 'windows',
      'icon_sizes': iconSizes(data),
      'running_first': data['running_first'] == true,
      'view_buttons': data['view_buttons'] == true,
      'filter_field': data['filter_field'] != false,
      'language': languageCodes.contains(data['language']) ? data['language'] : 'auto',
      'size': _size(data['size']),
      // The window's size outside popup mode (GTK's, title bar included), as the user left it.
      'window_size': _size(data['window_size']),
      // F12 saves a picture of the window (as in Maprisma); on by default.
      'screenshot_key': data['screenshot_key'] != false,
      'ai_enabled': data['ai_enabled'] != false,
      // auto: a popup on Hyprland (Omarchy as the old App Manager, Caelestia as the other
      // Maprisma windows), a window elsewhere.
      'window_mode': const ['auto', 'popup', 'window'].contains(data['window_mode']) ? data['window_mode'] : 'auto',
      // In popup mode, clicking outside hides the window (on by default).
      'close_outside': data['close_outside'] != false,
      // The package managers the user allows (null: the defaults, see Managers).
      'package_managers': data['package_managers'] is List
          ? [for (final m in data['package_managers'] as List) if (managerIds.contains(m)) m]
          : null,
      'screenshot_folder': _folder(data['screenshot_folder']),
      'header_order': headerOrder(data['header_order']),
      // Ask AI: your own suggestions under the field (null: the built-in ones).
      'ask_prompts': validPrompts(data['ask_prompts']) ? List<String>.from(data['ask_prompts'] as List) : null,
    };
  }

  static const maxPrompts = 12;

  /// ask_prompts: up to [maxPrompts] distinct, trimmed, non-empty requests
  /// of at most 2000 characters (the Ask field's limit).
  static bool validPrompts(Object? value) =>
      value is List &&
      value.length <= maxPrompts &&
      value.every((t) => t is String && t.isNotEmpty && t == t.trim() && t.length <= 2000) &&
      value.toSet().length == value.length;

  /// An absolute folder path, or null (~/Pictures/MaprismaLauncher).
  static String? _folder(Object? value) =>
      value is String && value.startsWith('/') && value.length <= 4096 && !value.contains('\x00') ? value : null;

  static List<int>? _size(Object? value) => value is List &&
          value.length == 2 &&
          value.every((v) => v is int && v >= 100 && v <= 20000)
      ? [value[0] as int, value[1] as int]
      : null;

  /// saved_icon_sizes: per view; the old single app_icon_size set the cards
  /// (and the list, 12 px less).
  static Map<String, int> iconSizes(Map data) {
    final sizes = {...defaultIconSizes};
    bool ok(String view, Object? v) => v is int && iconSizeChoices[view]!.contains(v);
    final stored = data['icon_sizes'];
    if (stored is Map) {
      for (final view in sizes.keys.toList()) {
        if (ok(view, stored[view])) sizes[view] = stored[view] as int;
      }
    } else {
      final old = data['app_icon_size'];
      if (ok('cards', old)) {
        sizes['cards'] = old as int;
        if (ok('list', old - 12)) sizes['list'] = old - 12;
      }
    }
    return sizes;
  }

  /// Back to the defaults (Settings › Reset to defaults): the layout and
  /// look settings go; groups, hidden entries and the window size stay.
  void reset() {
    final data = raw();
    for (final key in const [
      'view', 'wide_layout', 'shown_layouts', 'corners', 'icon_sizes', 'app_icon_size',
      'view_buttons', 'filter_field', 'running_first', 'language', 'screenshot_key', 'screenshot_folder', 'package_managers', 'window_mode', 'close_outside', 'header_order', 'ai_enabled',
    ]) {
      data.remove(key);
    }
    store.writeJson('settings.json', data);
  }

  /// Set one setting; a value that does not fit is refused.
  void set(String key, Object? value) {
    final current = read();
    Object? stored;
    switch (key) {
      case 'view':
        if (value != 'list' && value != 'groups' && value != 'origin') throw ArgumentError(key);
        stored = value;
      case 'wide_layout':
        if (!wideLayouts.contains(value)) throw ArgumentError(key);
        stored = value;
      case 'shown_layouts':
        if (value is! List) throw ArgumentError(key);
        final chosen = wideLayouts.where(value.contains).toList();
        stored = chosen.isEmpty ? [...wideLayouts] : chosen;
      case 'corners':
        if (!const ['windows', 'slight', 'rounded', 'square'].contains(value)) throw ArgumentError(key);
        stored = value;
      case 'window_mode':
        if (!const ['auto', 'popup', 'window'].contains(value)) throw ArgumentError(key);
        stored = value;
      case 'header_order':
        if (value is! List || value.length > 32 || value.any((id) => !headerButtons.contains(id))) {
          throw ArgumentError(key);
        }
        stored = headerOrder(value);
      case 'package_managers':
        if (value is! List || value.any((m) => !managerIds.contains(m))) throw ArgumentError(key);
        stored = [for (final id in managerIds) if (value.contains(id)) id];
      case 'ask_prompts':
        // null: back to the built-in suggestions.
        if (value == null) {
          store.writeJson('settings.json', {...raw()}..remove(key));
          return;
        }
        if (!validPrompts(value)) throw ArgumentError(key);
        stored = List<String>.from(value as List);
      case 'screenshot_folder':
        // null: back to the default folder.
        if (value == null) {
          store.writeJson('settings.json', {...raw()}..remove(key));
          return;
        }
        stored = _folder(value);
        if (stored == null) throw ArgumentError(key);
      case 'running_first' || 'view_buttons' || 'filter_field' || 'screenshot_key' || 'ai_enabled' || 'close_outside':
        if (value is! bool) throw ArgumentError(key);
        stored = value;
      case 'language':
        // i18n.save_language: "auto" (the system's) removes the key.
        if (value == 'auto') {
          store.writeJson('settings.json', {...raw()}..remove('language'));
          return;
        }
        if (!languageCodes.contains(value)) throw ArgumentError(key);
        stored = value;
      case 'size' || 'window_size':
        stored = _size(value);
        if (stored == null) throw ArgumentError(key);
      case 'icon_size':
        if (value is! Map || iconSizeChoices[value['view']] == null) throw ArgumentError(key);
        final view = value['view'] as String, size = value['size'];
        if (size is! int || !iconSizeChoices[view]!.contains(size)) throw ArgumentError(key);
        key = 'icon_sizes';
        stored = {...current['icon_sizes'] as Map, view: size};
      default:
        throw ArgumentError(key);
    }
    store.writeJson('settings.json', {...raw(), key: stored});
  }
}

/// hidden.json: desktop ids hidden from the list.
Set<String> loadHidden(ConfigStore store) {
  final data = store.readJson('hidden.json');
  return data is List ? {for (final v in data) if (v is String) v} : {};
}

void saveHidden(ConfigStore store, Set<String> hidden) =>
    store.writeJson('hidden.json', hidden.toList()..sort());

/// Write [text] to [path] atomically (a private temporary file next to it,
/// then renamed over it): a reader such as COSMIC or Hyprland sees the old
/// file or the new one, never half of it. A file that was there keeps its
/// permission bits; a link there is replaced, never followed.
void writeTextAtomic(String path, String text) {
  final dir = Directory(p.dirname(path));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final old = FileStat.statSync(path);
  final tmp = File(p.join(dir.path, '.${p.basename(path)}.$pid.tmp'));
  try {
    tmp.deleteSync();
  } on FileSystemException {
    // Nothing there.
  }
  if (!Posix.instance.writeNewPrivate(tmp.path, utf8.encode(text))) {
    if (tmp.existsSync()) tmp.deleteSync();
    throw FileSystemException('Could not write', path);
  }
  try {
    if (old.type == FileSystemEntityType.file) {
      Process.runSync('chmod', [(old.mode & 0x1ff).toRadixString(8), tmp.path]);
    }
    tmp.renameSync(path);
  } catch (_) {
    if (tmp.existsSync()) tmp.deleteSync();
    rethrow;
  }
}
