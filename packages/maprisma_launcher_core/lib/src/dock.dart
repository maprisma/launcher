/// The dock (reference/omarchy-plugin/dock_core.py): settings, pinned apps
/// and what the dock shows. Omarchy (Hyprland) only, as in the reference;
/// the dock itself is `maprisma-launcher --dock` (flutter_app/lib/dock).
///
/// Settings live in settings.json (keys "dock_*"), so the dock process sees
/// a change made in the app's Settings at once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'desktop_entries.dart';
import 'hyprland.dart';
import 'posix.dart';

const dockPositions = ['bottom', 'top', 'left', 'right'];
const dockAligns = ['start', 'center', 'end'];
const _opposite = {'bottom': 'top', 'top': 'bottom', 'left': 'right', 'right': 'left'};
const dockHeights = [32, 40, 48, 56, 64, 72, 80, 96];
const dockIconSizes = [24, 32, 40, 48, 56, 64, 72, 80, 96];
const dockMagnify = [100, 125, 150, 175, 200];
const dockSpacings = [0, 2, 4, 6, 8, 12, 16];
const dockIndicators = ['dot', 'line'];
const dockIndicatorColors = ['theme', 'foreground', 'red', 'yellow', 'green', 'orange'];
const dockChoices = <String, List<Object>>{
  'dock_height': dockHeights,
  'dock_icon_size': dockIconSizes,
  'dock_magnify': dockMagnify,
  'dock_spacing': dockSpacings,
  'dock_position': dockPositions,
  'dock_align': dockAligns,
  'dock_indicator': dockIndicators,
  'dock_indicator_color': dockIndicatorColors,
};
const dockItemExtra = 14; // Around an icon: the button's padding and the room for the running mark.
const dockBounce = 14; // How far an icon jumps when its app wants attention.
const dockDefaults = <String, Object>{
  'dock_enabled': false,
  'dock_position': 'bottom',
  'dock_align': 'center',
  'dock_height': 48,
  'dock_icon_size': 32,
  'dock_spacing': 6,
  'dock_magnify': 100,
  'dock_bounce': false,
  'dock_indicator_shown': true,
  'dock_indicator': 'line',
  'dock_indicator_color': 'theme',
  'dock_autohide': false,
  'dock_full_width': false,
  'dock_rounded': false,
  'dock_transparent': false,
  'dock_pinned': <String>[],
};
const _dockSwitches = [
  'dock_enabled', 'dock_autohide', 'dock_full_width', 'dock_rounded', 'dock_transparent', 'dock_bounce',
  'dock_indicator_shown',
];
const maxPinned = 60;

/// What "Reset to defaults" sets back, the dock itself off included; the
/// pinned apps stay for when it is switched on again.
const dockResetKeys = [
  'dock_enabled', 'dock_position', 'dock_align', 'dock_height', 'dock_icon_size', 'dock_spacing',
  'dock_magnify', 'dock_bounce', 'dock_autohide', 'dock_full_width', 'dock_rounded', 'dock_transparent',
  'dock_indicator_shown', 'dock_indicator', 'dock_indicator_color',
];

/// The layer surface's namespace (`hyprctl layers`).
const dockNamespace = 'maprisma-launcher-dock';

/// The GTK3 layer-shell library the dock loads at run time (package gtk-layer-shell).
const layerShellLibrary = 'libgtk-layer-shell.so.0';

/// Python's len(): code points, not UTF-16 units.
int _pyLen(String s) => s.runes.length;

bool _isNum(Object? v) => v is num;

/// Python's `value in allowed` for JSON values: 48.0 equals 48, a bool is
/// never a choice.
bool _inChoices(Object? value, List<Object> allowed) =>
    value is! bool && allowed.any((a) => a is num ? _isNum(value) && a == value : a == value);

/// dock_core.settings: each one checked; anything odd falls back to its default.
Map<String, dynamic> dockSettings(Map raw) {
  final result = <String, dynamic>{...dockDefaults, 'dock_pinned': <String>[]};
  for (final key in _dockSwitches) {
    if (raw[key] is bool) result[key] = raw[key];
  }
  for (final e in dockChoices.entries) {
    final value = raw[e.key];
    if (_inChoices(value, e.value)) result[e.key] = value;
  }
  final pinned = raw['dock_pinned'];
  if (pinned is List) {
    final seen = <String>{};
    result['dock_pinned'] = [
      for (final v in pinned)
        if (v is String && _pyLen(v) > 0 && _pyLen(v) <= 300 && seen.add(v)) v,
    ].take(maxPinned).toList();
  }
  return result;
}

/// dock_core.edge: the edge the dock really uses, never the bar's (the opposite then).
String dockEdge(Map dock, String bar) {
  final position = dock['dock_position'] as String;
  return position == bar ? _opposite[position]! : position;
}

int _pyRound(num x) {
  // Python's round(): halves to even.
  final f = x.floorToDouble();
  final diff = x - f;
  if (diff > .5) return f.toInt() + 1;
  if (diff < .5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// dock_core.sizes: (band, item, room): the band's thickness, an item's
/// (icon, padding, mark) and the window's whole thickness, with room above
/// the band for icons that stick out, grow on hover or bounce.
(int, int, int) dockSizes(Map dock) {
  final band = (dock['dock_height'] as num).toInt();
  final icon = (dock['dock_icon_size'] as num).toInt();
  final item = icon + dockItemExtra;
  final grow = dockGrow(dock);
  final bounce = dock['dock_bounce'] == true ? dockBounce : 0;
  final room = band > item + grow + bounce ? band : item + grow + bounce;
  return (band, item, room);
}

/// How many pixels the icon under the pointer grows.
int dockGrow(Map dock) =>
    _pyRound((dock['dock_icon_size'] as num) * ((dock['dock_magnify'] as num) - 100) / 100);

/// Python's int() for a JSON value: null when it would raise.
int? _pyInt(Object? v) {
  if (v is bool) return v ? 1 : 0;
  if (v is int) return v;
  if (v is double) return v.isFinite ? v.truncate() : null;
  if (v is String) return int.tryParse(v.trim().replaceAll('_', ''));
  return null;
}

/// dock_core.dock_rect: the dock's surface on screen ((x, y, w, h) in global
/// logical pixels, the monitor's origin) from `hyprctl layers -j` /
/// `monitors -j`; null when no dock is mapped.
((int, int, int, int), (Object?, Object?))? dockRect(Object? layers, Object? monitors, {String namespace = dockNamespace}) {
  if (layers is! Map) return null;
  final origins = <Object?, (Object?, Object?)>{
    for (final m in monitors is List ? monitors : const [])
      if (m is Map) m['name']: (m.containsKey('x') ? m['x'] : 0, m.containsKey('y') ? m['y'] : 0),
  };
  for (final e in layers.entries) {
    final monitor = e.value;
    final levels = monitor is Map ? (monitor['levels'] ?? const {}) : const {};
    if (levels is! Map) return null;
    for (final surfaces in levels.values) {
      for (final layer in surfaces is List ? surfaces : const []) {
        if (layer is Map && layer['namespace'] == namespace) {
          final values = [for (final k in const ['x', 'y', 'w', 'h']) _pyInt(layer[k])];
          if (values.any((v) => v == null)) return null;
          return ((values[0]!, values[1]!, values[2]!, values[3]!), origins[e.key] ?? (0, 0));
        }
      }
    }
  }
  return null;
}

/// dock_core.inside: a `hyprctl cursorpos -j` point within the rectangle.
bool dockInside(Object? point, (num, num, num, num) rect) {
  if (point is! Map) return false;
  final (x, y, w, h) = rect;
  final px = point.containsKey('x') ? point['x'] : -1, py = point.containsKey('y') ? point['y'] : -1;
  if (px is! num || py is! num) return false;
  return x <= px && px < x + w && y <= py && py < y + h;
}

/// dock_core.indicator_color: the running mark's colour from the theme palette.
Object? dockIndicatorColor(Map dock, Map colors) {
  final key = dock.containsKey('dock_indicator_color') ? dock['dock_indicator_color'] : 'theme';
  final value = colors[key == 'theme' ? 'accent' : key];
  bool truthy(Object? v) => v != null && v != '' && v != false && v != 0;
  if (truthy(value)) return value;
  return colors.containsKey('accent') ? colors['accent'] : '#888888';
}

/// dock_core.has_new_window_action: the app's own "New Window" action (browsers).
bool hasNewWindowAction(Map app) {
  final actions = app['actions'];
  if (actions is! List) return false;
  return actions.any((a) {
    final id = '${(a is Map ? a['id'] : null) ?? ''}'.toLowerCase().replaceAll('_', '-');
    return id == 'new-window' || id == 'newwindow';
  });
}

/// dock_core.split_events: Hyprland's event stream split into lines without
/// ever holding a long one: (complete lines, the unfinished rest, skipping).
/// A line longer than [limit] (a window title from a web page) is dropped up
/// to its end.
(List<String>, Uint8List, bool) splitEvents(List<int> buffer, List<int> chunk, bool skipping, {int limit = 4096}) {
  final all = Uint8List(buffer.length + chunk.length)
    ..setAll(0, buffer)
    ..setAll(buffer.length, chunk);
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < all.length; i++) {
    if (all[i] != 10) continue;
    final length = i - start;
    if (skipping) {
      skipping = false; // The end of a line that was too long.
    } else if (length <= limit) {
      out.add(utf8.decode(Uint8List.sublistView(all, start, i), allowMalformed: true));
    }
    start = i + 1;
  }
  var rest = Uint8List.fromList(Uint8List.sublistView(all, start));
  if (rest.length > limit) {
    rest = Uint8List(0);
    skipping = true;
  }
  return (out, rest, skipping);
}

/// dock_core.move_pinned: ids with [id] moved right before (or after) [target].
List<String> movePinned(List<String> ids, String id, String target, {bool after = false}) {
  final rest = [for (final i in ids) if (i != id) i];
  if (!rest.contains(target)) return ids;
  rest.insert(rest.indexOf(target) + (after ? 1 : 0), id);
  return rest;
}

/// dock_core.insert_pinned: ids with [id] placed before (or after)
/// [target]; at the end without one. Already pinned: moved there.
List<String> insertPinned(List<String> ids, String id, {String? target, bool after = false}) {
  final rest = [for (final i in ids) if (i != id) i];
  final index = target != null && rest.contains(target) ? rest.indexOf(target) + (after ? 1 : 0) : rest.length;
  rest.insert(index, id);
  return rest.take(maxPinned).toList();
}

/// What the app offers when an entry is dragged out of it.
const dropPrefix = 'app-manager-entry:';
const maxDropBytes = 512;

/// Python's str.isspace() characters (str.strip() without arguments).
bool _pySpace(int c) =>
    (c >= 9 && c <= 13) || (c >= 0x1c && c <= 0x20) || c == 0x85 || c == 0xa0 || c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;

/// dock_core.dropped_id: the desktop id in a drop, else null (a byte cap,
/// UTF-8 only, the prefix, one line).
String? droppedId(Object? data) {
  if (data is! List<int> || data.length > maxDropBytes) return null;
  String text;
  try {
    text = utf8.decode(data);
  } on FormatException {
    return null;
  }
  var runes = text.runes.toList();
  var a = 0, b = runes.length;
  while (a < b && _pySpace(runes[a])) {
    a++;
  }
  while (b > a && _pySpace(runes[b - 1])) {
    b--;
  }
  runes = runes.sublist(a, b);
  while (runes.isNotEmpty && runes.last == 0) {
    runes.removeLast();
  }
  text = String.fromCharCodes(runes);
  if (!text.startsWith(dropPrefix)) return null;
  final id = text.substring(dropPrefix.length);
  return _pyLen(id) > 0 && _pyLen(id) <= 300 && !id.contains('\n') ? id : null;
}

/// dock_core.clients: Hyprland's mapped windows.
List<Map> dockClients(Object? data) => data is List
    ? [for (final c in data) if (c is Map && (!c.containsKey('mapped') || _truthy(c['mapped']))) c]
    : const [];

bool _truthy(Object? v) => v != null && v != false && v != 0 && v != '' && !(v is List && v.isEmpty) && !(v is Map && v.isEmpty);

int _focusOrder(Map c) {
  final v = c.containsKey('focusHistoryID') ? c['focusHistoryID'] : 1 << 30;
  return v is int ? v : 1 << 30;
}

/// dock_core.windows_of: the app's windows, most recently focused first.
List<Map> dockWindowsOf(Map app, List<Map> clients) {
  final classes = appWindowClasses(app);
  final found = [for (final c in clients) if (clientMatchesApp(c, app, classes)) c];
  mergeSort(found, compare: (a, b) => _focusOrder(a).compareTo(_focusOrder(b)));
  return found;
}

/// Python's str.casefold() closely enough for app names.
String _fold(String s) => s.toLowerCase().replaceAll('ß', 'ss');

/// dock_core.items: [(app, windows, pinned)]: the pinned apps in their
/// order, then the other apps that have windows open, by name.
List<(Map, List<Map>, bool)> dockItems(List<Map> apps, List<String> pinned, List<Map> clients) {
  final byId = <Object?, Map>{
    for (final a in apps)
      if (_truthy(a['desktop_id'])) a['desktop_id']: a,
  };
  final result = <(Map, List<Map>, bool)>[];
  for (final id in pinned) {
    final app = byId[id];
    if (app != null) result.add((app, dockWindowsOf(app, clients), true));
  }
  final pinnedSet = pinned.toSet();
  final running = <(Map, List<Map>)>[];
  for (final app in apps) {
    if (pinnedSet.contains(app['desktop_id']) || app.containsKey('tray_id')) continue;
    final found = dockWindowsOf(app, clients);
    if (found.isNotEmpty) running.add((app, found));
  }
  // Most recently used first would reshuffle on every focus change: a stable order by name.
  mergeSort(running, compare: (a, b) => _fold('${a.$1['name']}').compareTo(_fold('${b.$1['name']}')));
  for (final (app, found) in running) {
    result.add((app, found, false));
  }
  return result;
}

/// dock.on_event: one Hyprland event line; [urgent] (window addresses that
/// asked for attention) is updated. True when the dock should look again.
bool dockEvent(String line, Set<String> urgent, {int maxUrgent = 256}) {
  final head = line.runes.length > 512 ? String.fromCharCodes(line.runes.take(512)) : line;
  final cut = head.indexOf('>>');
  final name = cut < 0 ? head : head.substring(0, cut);
  final data = cut < 0 ? '' : head.substring(cut + 2);
  final address = '0x${data.split(',').first}';
  if (name == 'urgent' && urgent.length < maxUrgent) {
    urgent.add(address);
  } else if (name == 'activewindowv2') {
    urgent.remove(address); // Seen: stop bouncing.
  }
  if (const {'urgent', 'activewindowv2', 'openwindow', 'closewindow', 'movewindowv2', 'windowtitlev2'}.contains(name)) {
    if (name == 'closewindow') urgent.remove(address);
    return true;
  }
  return false;
}

/// Hyprland's event socket (socket2), as lines; long lines are dropped
/// (splitEvents). Reconnects when Hyprland restarts.
final class HyprEvents {
  HyprEvents(this.path, {this.limit = 4096});
  final String path;
  final int limit;

  /// `$XDG_RUNTIME_DIR/hypr/<signature>/.socket2.sock`, or null.
  static String? socketPath(Map<String, String> env) {
    final signature = env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '', runtime = env['XDG_RUNTIME_DIR'] ?? '';
    if (signature.isEmpty || runtime.isEmpty || signature.contains('/') || signature == '..') return null;
    return p.join(runtime, 'hypr', signature, '.socket2.sock');
  }

  /// The event lines until [stop] completes; reconnecting after [retry].
  Stream<String> lines({Duration retry = const Duration(seconds: 3), Future<void>? stop}) async* {
    var stopped = false;
    stop?.then((_) => stopped = true);
    while (!stopped) {
      Socket? socket;
      try {
        socket = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0)
            .timeout(const Duration(seconds: 2));
      } on Object {
        socket = null;
      }
      if (socket != null) {
        var buffer = Uint8List(0);
        var skipping = false;
        final done = stop?.then((_) => socket?.destroy());
        try {
          await for (final chunk in socket) {
            final (out, rest, skip) = splitEvents(buffer, chunk, skipping, limit: limit);
            buffer = rest;
            skipping = skip;
            for (final line in out) {
              yield line;
            }
            if (stopped) break;
          }
        } on Object {
          // Hyprland went away: connect again.
        }
        socket.destroy();
        done?.ignore();
      }
      if (stopped) break;
      await Future.any([Future<void>.delayed(retry), ?stop]);
    }
  }
}

/// The dock's settings in settings.json, written atomically through the store.
final class DockStore {
  DockStore(this.store);
  final ConfigStore store;

  Map<String, dynamic> _raw() {
    final data = store.readJson('settings.json', cap: 64 * 1024);
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  Map<String, dynamic> read() => dockSettings(_raw());

  void _save(Map<String, Object?> values) => store.writeJson('settings.json', {..._raw(), ...values});

  /// dock_core.set_setting: one of a choice's values, or a switch (any value,
  /// taken as Python's bool()); never the pinned list.
  void set(String key, Object? value) {
    if (!dockDefaults.containsKey(key) || key == 'dock_pinned') throw ArgumentError(key);
    final choices = dockChoices[key];
    if (choices != null) {
      if (!_inChoices(value, choices)) throw ArgumentError(key);
      _save({key: value});
    } else {
      _save({key: _truthy(value)}); // As the reference: bool(value).
    }
  }

  void reset() => _save({for (final k in dockResetKeys) k: dockDefaults[k]});

  List<String> pinned() => List<String>.from(read()['dock_pinned'] as List);

  void setPinned(List<String> ids) {
    final seen = <String>{};
    _save({'dock_pinned': [for (final i in ids) if (seen.add(i)) i].take(maxPinned).toList()});
  }

  void pin(String id) {
    final ids = pinned();
    if (!ids.contains(id)) setPinned([...ids, id]);
  }

  void unpin(String id) => setPinned([for (final i in pinned()) if (i != id) i]);
}

/// dock_core.bar_position: the edge Omarchy's bar is on (shell.json
/// "bar.position"), "top" by default.
String barPosition(Session session, {String? path}) {
  final file = path ?? p.join(session.home, '.config/omarchy/shell.json');
  final bytes = Posix.instance.readRegular(file, 1024 * 1024);
  Object? position;
  if (bytes != null) {
    try {
      final data = jsonDecode(utf8.decode(bytes).isEmpty ? '{}' : utf8.decode(bytes));
      final bar = data is Map ? data['bar'] : null;
      position = bar is Map ? bar['position'] : null;
    } on FormatException {
      position = null;
    }
  }
  return dockPositions.contains(position) ? position as String : 'top';
}

/// The layer-shell library is there (the dock process loads it itself and
/// refuses to start without it; this only tells Settings).
bool layerShellInstalled({List<String> dirs = const ['/usr/lib', '/usr/lib64', '/usr/lib/x86_64-linux-gnu', '/lib/x86_64-linux-gnu', '/usr/local/lib']}) =>
    dirs.any((d) => File(p.join(d, layerShellLibrary)).existsSync());
