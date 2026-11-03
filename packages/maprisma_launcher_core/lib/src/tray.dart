/// Tray icons (StatusNotifierItem) and their menus, for the app's own Quit
/// (reference/omarchy-plugin tray.py: clean_label, slug, action_id,
/// _menu_nodes, item_key, _title, _owner_programs, find_quit, click; and
/// launcher_popup tray_app, quit_action). Apps are never ended by us: only
/// their own tray "Quit …" entry is clicked, a clean exit.
///
/// D-Bus goes through systemd's `busctl --json` (argv only, bounded output,
/// short timeouts), so no D-Bus library is needed. Names and object paths
/// from the bus are checked before they reach busctl's argv.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'posix.dart';
import 'running.dart';
import 'shlex.dart';

const _watcher = ('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.kde.StatusNotifierWatcher');
const _itemInterface = 'org.kde.StatusNotifierItem';
const _menuInterface = 'com.canonical.dbusmenu';
final trayIdRe = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
final _genericIdRe = RegExp(r'^(chrome_status_icon|electron|tray|statusicon)[_-]?\d*$', caseSensitive: false);
final _quitRe = RegExp(r'^(quit|exit|close|beenden)\b', caseSensitive: false);
final _busNameRe = RegExp(r'^(:[0-9]+\.[0-9]+|[A-Za-z_-][A-Za-z0-9_-]*(\.[A-Za-z_-][A-Za-z0-9_-]*)+)$');
final _objectPathRe = RegExp(r'^/([A-Za-z0-9_]+(/[A-Za-z0-9_]+)*)?$');
const _maxDepth = 8, _maxNodes = 2000;

/// clean_label: GTK mnemonic underscores out ("_Quit" → "Quit", "a__b" → "a_b").
String cleanLabel(Object? label) =>
    '${label ?? ''}'.replaceAllMapped(RegExp(r'_(.)'), (m) => m[1]!).trim();

/// slug: Python's casefold() differs from toLowerCase() only for a few
/// letters (ß → ss); the id is a stable name, not shown.
String traySlug(String label) {
  final s = label.toLowerCase().replaceAll('ß', 'ss').replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  final trimmed = s.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.isEmpty ? 'item' : trimmed;
}

String actionId(List<String> trail) {
  final id = trail.map(traySlug).join('.');
  return id.length > 64 ? id.substring(0, 64) : id;
}

/// _menu_nodes over plain layout children: [id, {prop: value}, [children]].
List<Map<String, dynamic>> menuNodes(List children, [List<String> trail = const [], int depth = 0]) {
  final nodes = <Map<String, dynamic>>[];
  if (depth > _maxDepth) return nodes;
  for (final child in children) {
    if (child is! List || child.length < 3 || child[1] is! Map) continue;
    final props = child[1] as Map;
    if (props['visible'] == false) continue;
    if (props['type'] == 'separator') {
      nodes.add({'separator': true});
      continue;
    }
    final label = cleanLabel(props['label'] ?? '');
    if (label.isEmpty) continue;
    final id = child[0];
    if (id is! int) continue;
    final path = [...trail, label];
    final toggle = props['toggle-type'];
    nodes.add({
      'id': id,
      'label': label,
      'action': actionId(path),
      'enabled': props['enabled'] != false,
      'toggle': toggle == 'checkmark' || toggle == 'radio' ? toggle : '',
      'checked': props['toggle-state'] == 1,
      'children': menuNodes(child[2] is List ? child[2] as List : const [], path, depth + 1),
    });
  }
  return nodes;
}

/// find_quit: the app's own quit entry ("Quit LM Studio", "Exit Steam"),
/// top level only, enabled, without a submenu.
Map<String, dynamic>? findQuit(List<Map<String, dynamic>> nodes) {
  for (final node in nodes) {
    if (node['separator'] == true || node['enabled'] != true) continue;
    if ((node['children'] as List).isEmpty && _quitRe.hasMatch(node['label'] as String)) return node;
  }
  return null;
}

/// item_key: the name a tray icon goes by. Electron apps all say
/// "chrome_status_icon_1", so those go by their title.
String? itemKey(String rawId, String title, Set<String> taken) {
  if (rawId.isEmpty && title.isEmpty) return null;
  if (rawId.isNotEmpty && trayIdRe.hasMatch(rawId) && !_genericIdRe.hasMatch(rawId) && !taken.contains(rawId)) {
    return rawId;
  }
  var key = traySlug(title.isNotEmpty ? title : rawId);
  if (key.length > 64) key = key.substring(0, 64);
  return trayIdRe.hasMatch(key) && !taken.contains(key) ? key : null;
}

/// _title: Title, else the tooltip's title (Electron leaves Title empty).
String trayTitle(Map props) {
  final title = cleanLabel(props['Title'] ?? '');
  if (title.isNotEmpty) return title;
  final tooltip = props['ToolTip'];
  return tooltip is List && tooltip.length > 2 ? cleanLabel(tooltip[2]) : '';
}

/// busctl's JSON variant {"type": …, "data": …} → its plain value; layout
/// structs (ia{sv}av) → [id, props, children].
Object? _plain(Object? v, [int depth = 0]) {
  if (depth > 3 * _maxDepth) return null;
  if (v is Map && v.containsKey('type') && v.containsKey('data') && v.length == 2) {
    return _plain(v['data'], depth + 1);
  }
  if (v is Map) return {for (final e in v.entries) '${e.key}': _plain(e.value, depth + 1)};
  if (v is List) return [for (final x in v) _plain(x, depth + 1)];
  return v;
}

final class Tray {
  Tray(this.session, {this.proc = '/proc'});
  final Session session;
  final String proc;

  /// busctl's output, or null when it failed (a call without a reply
  /// prints nothing).
  Future<String?> _run(List<String> args, {int maxBytes = 1024 * 1024}) async {
    final busctl = session.which('busctl');
    if (busctl == null) return null;
    // `--` ends busctl's options: nothing from the bus can become one.
    return readBoundedText([busctl, '--user', '--json=short', '--timeout=1.5', '--', ...args],
        maxBytes: maxBytes, timeout: const Duration(seconds: 2), environment: session.environment);
  }

  Future<Object?> _call(List<String> args) async {
    final out = await _run(args);
    if (out == null) return null;
    try {
      return jsonDecode(out);
    } on FormatException {
      return null;
    }
  }

  /// `<service>/<path>` → (service, path), both checked; null when odd.
  static (String, String)? split(String entry) {
    final i = entry.indexOf('/');
    final (name, path) = i < 0 ? (entry, '/StatusNotifierItem') : (entry.substring(0, i), entry.substring(i));
    return _busNameRe.hasMatch(name) && name.length <= 255 && _objectPathRe.hasMatch(path) && path.length <= 255
        ? (name, path)
        : null;
  }

  Future<List<String>> registered() async {
    final r = await _call(['get-property', _watcher.$1, _watcher.$2, _watcher.$3, 'RegisteredStatusNotifierItems']);
    final data = r is Map ? r['data'] : null;
    return data is List ? data.whereType<String>().take(200).toList() : const [];
  }

  /// _owner_programs: the program names behind a tray icon (its executable,
  /// argv[0], ARGV0/APPIMAGE), only for our own processes.
  Future<Set<String>> ownerPrograms(String name) async {
    final r = await _call(['call', 'org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
        'GetConnectionUnixProcessID', 's', name]);
    final data = r is Map ? r['data'] : null;
    final pid = data is List && data.isNotEmpty ? data.first : null;
    if (pid is! int || pid <= 0) return {};
    return programsOf(pid);
  }

  Set<String> programsOf(int pid) {
    final dir = p.join(proc, '$pid');
    if (Posix.instance.ownerOf(dir) != Posix.instance.uid) return {};
    final names = <String>{};
    try {
      names.add(p.basename(Link(p.join(dir, 'exe')).targetSync()));
    } on FileSystemException {
      // Gone, or not ours to read.
    }
    final cmdline = _readProc(p.join(dir, 'cmdline'));
    if (cmdline != null) names.add(p.basename(cmdline.split('\x00').first));
    final environ = _readProc(p.join(dir, 'environ'));
    for (final line in (environ ?? '').split('\x00')) {
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      final key = line.substring(0, eq), value = line.substring(eq + 1);
      if ((key == 'ARGV0' || key == 'APPIMAGE') && value.isNotEmpty) {
        var base = p.basename(value);
        for (final suffix in ['.AppImage', '.appimage']) {
          if (base.endsWith(suffix)) base = base.substring(0, base.length - suffix.length);
        }
        names.add(base);
      }
    }
    return {for (final n in names) if (n.isNotEmpty) n.toLowerCase()};
  }

  /// /proc files say size 0: read them in pieces, at most 1 MiB.
  static String? _readProc(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final bytes = BytesBuilder(copy: false);
      while (bytes.length < 1024 * 1024) {
        final chunk = f.readSync(64 * 1024);
        if (chunk.isEmpty) break;
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    } on FileSystemException {
      return null;
    } finally {
      f?.closeSync();
    }
  }

  Future<List<Map<String, dynamic>>> readMenu(String name, String menuPath) async {
    if (!_objectPathRe.hasMatch(menuPath)) return const [];
    // Some apps fill their menu only when it is about to be shown.
    await _call(['call', name, menuPath, _menuInterface, 'AboutToShow', 'i', '0']);
    final r = await _call(['call', name, menuPath, _menuInterface, 'GetLayout', 'iias', '0', '-1', '0']);
    final layout = _plain(r is Map ? r['data'] : null);
    if (layout is! List || layout.length < 2 || layout[1] is! List) return const [];
    final root = layout[1] as List;
    if (root.length < 3 || root[2] is! List) return const [];
    final nodes = menuNodes(root[2] as List);
    return _count(nodes) > _maxNodes ? const [] : nodes;
  }

  static int _count(List<Map<String, dynamic>> nodes) =>
      nodes.fold(0, (n, x) => n + 1 + _count((x['children'] as List? ?? const []).cast<Map<String, dynamic>>()));

  /// list_items: the registered tray icons with their menus.
  Future<List<Map<String, dynamic>>> items() async {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final entry in await registered()) {
      final at = split(entry);
      if (at == null) continue;
      final (name, path) = at;
      final r = await _call(['call', name, path, 'org.freedesktop.DBus.Properties', 'GetAll', 's', _itemInterface]);
      final data = _plain(r is Map ? r['data'] : null);
      if (data is! List || data.isEmpty || data.first is! Map) continue;
      final props = data.first as Map;
      var title = trayTitle(props);
      final programs = await ownerPrograms(name);
      if (title.isEmpty && programs.isNotEmpty) title = (programs.toList()..sort()).first;
      final id = itemKey('${props['Id'] ?? ''}', title, seen);
      if (id == null) continue;
      seen.add(id);
      final menuPath = '${props['Menu'] ?? ''}';
      out.add({
        'name': title.isEmpty ? id : title,
        'tray_id': id,
        'tray_service': name,
        'tray_menu_path': menuPath,
        'tray_programs': programs,
        'tray_menu': menuPath.startsWith('/') ? await readMenu(name, menuPath) : const <Map<String, dynamic>>[],
      });
    }
    return out;
  }

  /// tray_app: does this tray icon belong to the app? By desktop id or name,
  /// else by the process behind the icon (LM Studio runs as lm-studio).
  static bool belongsTo(Map item, Map app) {
    final key = (item['tray_id'] as String).toLowerCase();
    if ('${app['desktop_id']}'.toLowerCase() == key) return true;
    if ('${app['name']}'.toLowerCase() == '${item['name']}'.toLowerCase()) return true;
    final programs = item['tray_programs'] as Set<String>? ?? const {};
    if (programs.isEmpty) return false;
    final process = appProcessName(app);
    if (process != null && programs.contains(process)) return true;
    try {
      final args = shlexSplit(app['exec'] as String? ?? '');
      return args.isNotEmpty && programs.contains(p.basenameWithoutExtension(args.first).toLowerCase());
    } on FormatException {
      return false;
    }
  }

  /// The app's own Quit: (item, node), or null. The first matching icon
  /// with a Quit entry wins.
  Future<(Map<String, dynamic>, Map<String, dynamic>)?> quitFor(Map app) async {
    for (final item in await items()) {
      if (!belongsTo(item, app)) continue;
      final node = findQuit((item['tray_menu'] as List).cast<Map<String, dynamic>>());
      if (node != null) return (item, node);
    }
    return null;
  }

  /// click: the menu entry's "clicked" event.
  Future<bool> click(Map item, int nodeId) async {
    final name = item['tray_service'] as String, path = item['tray_menu_path'] as String;
    if (!_busNameRe.hasMatch(name) || !_objectPathRe.hasMatch(path)) return false;
    return await _run(['call', name, path, _menuInterface, 'Event', 'isvu', '$nodeId', 'clicked', 'i', '0', '0']) != null;
  }
}
