/// Hyprland on Omarchy (reference/omarchy-plugin: desktop_omarchy.py and
/// launcher_core.py): which windows belong to an app, switching to one,
/// starting an app floating or on a workspace, and the popup's place.
/// Hyprland 0.55+ takes Lua through `hyprctl dispatch` / `hyprctl eval`; only
/// hex window addresses from `hyprctl clients -j`, workspace numbers 1–100
/// and fully escaped Lua strings ever go into it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'running.dart';
import 'shlex.dart';

final _address = RegExp(r'^0x[0-9a-fA-F]{1,16}$');
const maxWorkspace = 100;

/// launcher_core.app_window_classes: the window classes an app may have.
Set<String> appWindowClasses(Map app) {
  final explicit = app['startup_class'] as String? ?? '';
  final names = <String>{explicit, app['desktop_id'] as String? ?? ''};
  List<String> args;
  try {
    args = shlexSplit(app['exec'] as String? ?? '');
  } on FormatException {
    args = const [];
  }
  if (args.isNotEmpty) {
    final executable = p.basename(args.first);
    final hasClassArgument = args.any(
      (a) => a.startsWith('--class=') || a.startsWith('--app-id=') || a == '--class' || a == '--app-id',
    );
    if (explicit.isEmpty && !hasClassArgument && !const {'env', 'sh', 'bash', 'flatpak', 'gtk-launch'}.contains(executable)) {
      names.add(executable);
    }
    void addHost(String url) {
      final host = Uri.tryParse(url)?.authority ?? '';
      if (host.isNotEmpty) {
        names.addAll(['chrome-${host}__-default', 'chromium-${host}__-default', 'chrome-$host', 'chromium-$host']);
      }
    }

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('--class=') || arg.startsWith('--app-id=')) {
        names.add(arg.substring(arg.indexOf('=') + 1));
      } else if ((arg == '--class' || arg == '--app-id') && i + 1 < args.length) {
        names.add(args[i + 1]);
      } else if (arg.startsWith('--app=')) {
        addHost(arg.substring(6));
      } else if (arg == '--app' && i + 1 < args.length) {
        addHost(args[i + 1]);
      }
    }
  }
  // crx / Chrome web-app ids in their Wayland and X11 forms.
  for (final cls in names.toList()) {
    final raw = cls.startsWith('crx_') ? cls.substring(4) : cls;
    if (raw != cls || RegExp(r'^\p{L}{32}$', unicode: true).hasMatch(raw)) {
      names.addAll(['crx_$raw', 'chrome-$raw-default', 'chromium-$raw-default', 'chrome-$raw', 'chromium-$raw']);
    }
  }
  return {for (final n in names) if (n.isNotEmpty) n.toLowerCase()};
}

/// launcher_core.client_matches_app, with Chromium web-app windows.
bool clientMatchesApp(Map client, Map app, [Set<String>? classes]) {
  classes ??= appWindowClasses(app);
  final clientClasses = {
    '${client['class'] ?? ''}'.toLowerCase(),
    '${client['initialClass'] ?? ''}'.toLowerCase(),
  }..remove('');
  if (classes.any(clientClasses.contains)) return true;
  for (final cls in clientClasses) {
    final m = RegExp(r'^(?:chrome|chromium|brave)-(.+?)(?:__.*|-.*)?$').firstMatch(cls);
    if (m == null) continue;
    final target = m[1]!.toLowerCase();
    final raw = (app['startup_class'] as String? ?? '').replaceFirst(RegExp(r'^crx_'), '').toLowerCase();
    if (raw.isNotEmpty && (target == raw || target.startsWith(raw))) return true;
    final title = '${client['title'] ?? ''}';
    final name = (app['name'] as String? ?? '').trim();
    if (name.isNotEmpty && (title.endsWith(' - $name') || title.endsWith(' — $name') || title == name)) return true;
    Set<String> tokens(String text) => {
      for (final t in RegExp(r'[a-z0-9]{3,}').allMatches(text)) t[0]!,
    };
    final targetTokens = tokens(target)..removeAll({'com', 'org', 'net', 'app', 'default', 'io'});
    final nameTokens = tokens(name.toLowerCase());
    if (targetTokens.isNotEmpty &&
        nameTokens.isNotEmpty &&
        (nameTokens.containsAll(targetTokens) || targetTokens.containsAll(nameTokens))) {
      return true;
    }
  }
  return false;
}

/// child_process_names: a window's process's direct children (exe and the
/// first two words), so `foot -e claude` belongs to Claude CLI.
Set<String> childProcessNames(Object? pid) {
  if (pid is! int || pid <= 0) return {};
  final names = <String>{};
  List<String> children;
  try {
    children = File('/proc/$pid/task/$pid/children').readAsStringSync().split(RegExp(r'\s+'));
  } on FileSystemException {
    return names;
  }
  for (final child in children.where((c) => RegExp(r'^\d+$').hasMatch(c))) {
    try {
      names.add(p.basename(Link('/proc/$child/exe').targetSync()).toLowerCase());
      final argv = File('/proc/$child/cmdline').readAsBytesSync();
      final words = String.fromCharCodes(argv).split('\x00').where((w) => w.isNotEmpty).take(2);
      names.addAll(words.map((w) => p.basename(w).toLowerCase()));
    } on FileSystemException {
      continue;
    }
  }
  return names;
}

/// desktop_omarchy.lua_string: every byte escaped (\ddd), so nothing in it
/// can end the string or reach the Lua code around it.
String luaString(String text) =>
    '"${utf8.encode(text).map((b) => '\\${b.toString().padLeft(3, '0')}').join()}"';

final class Hyprland {
  Hyprland(this.session);
  final Session session;
  bool get available => (session.environment['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty;

  Future<String?> _hyprctl(List<String> args) async {
    final hyprctl = session.which('hyprctl');
    if (hyprctl == null || !available) return null;
    return readBoundedText(
      [hyprctl, ...args],
      maxBytes: 4 * 1024 * 1024,
      timeout: const Duration(seconds: 2),
      environment: session.environment,
    );
  }

  Future<List<Map>> _list(String what) async {
    final text = await _hyprctl([what, '-j']);
    try {
      final data = text == null ? null : jsonDecode(text);
      return data is List ? data.whereType<Map>().toList() : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<List<Map>> clients() => _list('clients');

  /// Run states by key: "active" (a window), "background" (a process, no
  /// window); launcher_popup._app_state.
  Map<String, String> states(Map<String, Map> apps, List<Map> clients, Set<String> names, Map<String, int> exes) {
    final children = {for (final c in clients) c['pid']: childProcessNames(c['pid'])};
    final commands = {for (final app in apps.values) ?terminalCommand(app)};
    bool matches(Map client, Map app) {
      final kids = children[client['pid']] ?? const <String>{};
      final command = terminalCommand(app);
      if (command != null) {
        if (kids.contains(command)) return true;
      } else if (kids.any(commands.contains)) {
        return false;
      }
      return clientMatchesApp(client, app);
    }

    final claimed = {for (final c in clients) if ((children[c['pid']] ?? const {}).any(commands.contains)) c['pid']};
    final out = <String, String>{};
    for (final e in apps.entries) {
      if (clients.any((c) => matches(c, e.value))) {
        out[e.key] = 'active';
        continue;
      }
      final name = appProcessName(e.value);
      if (name == null || !names.contains(name)) continue;
      if (terminalPrograms.contains(name) && (exes[name] ?? 0) <= claimed.length) continue;
      out[e.key] = 'background';
    }
    return out;
  }

  /// app_windows: the app's windows by workspace, the last used first.
  List<Map<String, dynamic>> windowsOf(Map app, List<Map> clients) {
    final windows = [
      for (final c in clients)
        if (_address.hasMatch('${c['address']}') && clientMatchesApp(c, app)) c,
    ];
    int order(Object? v) => v is int && v > 0 ? v : 1 << 30;
    windows.sort((a, b) {
      final wa = order((a['workspace'] as Map?)?['id']), wb = order((b['workspace'] as Map?)?['id']);
      return wa != wb ? wa.compareTo(wb) : order(a['focusHistoryID']).compareTo(order(b['focusHistoryID']));
    });
    return [
      for (final w in windows)
        {
          'address': w['address'],
          'title': '${w['title'] ?? ''}'.length > 120 ? '${w['title']}'.substring(0, 120) : '${w['title'] ?? ''}',
          'workspace': (w['workspace'] as Map?)?['id'],
        },
    ];
  }

  /// focus_window: its workspace comes up and it gets the focus; the classic
  /// dispatcher when the Lua one is refused (as omarchy-launch-or-focus).
  Future<bool> focus(String address) async {
    if (!_address.hasMatch(address)) return false;
    final lua = await _hyprctl(['dispatch', 'hl.dsp.focus({window = ${jsonEncode('address:$address')}})']);
    if (lua != null && lua.trim() == 'ok') return true;
    return (await _hyprctl(['dispatch', 'focuswindow', 'address:$address'])) != null;
  }

  /// The dock's Close: Hyprland closes the window (the app may still ask to save).
  Future<bool> closeWindow(String address) async {
    if (!_address.hasMatch(address)) return false;
    final lua = await _hyprctl(['dispatch', 'hl.dsp.window.close({window = ${jsonEncode('address:$address')}})']);
    if (lua != null && lua.trim() == 'ok') return true;
    return (await _hyprctl(['dispatch', 'closewindow', 'address:$address']))?.trim() == 'ok';
  }

  /// A window address as Hyprland writes it (0x and hex digits).
  static bool validAddress(Object? address) => address is String && _address.hasMatch(address);

  /// _exec_with_rule: Hyprland starts argv with a rule for its first window.
  Future<bool> execWithRule(List<String> argv, String rule) async {
    final out = await _hyprctl(['eval', 'hl.exec_cmd(${luaString(shlexJoin(argv))}, {$rule})']);
    return out?.trim() == 'ok';
  }

  Future<bool> execFloating(List<String> argv) => execWithRule(argv, 'float = true');

  Future<bool> execOnWorkspace(List<String> argv, int workspace) =>
      workspace >= 1 && workspace <= maxWorkspace ? execWithRule(argv, 'workspace = $workspace') : Future.value(false);

  /// workspaces: the normal workspaces in use with their apps, and the first free one.
  Future<Map<String, dynamic>?> workspaces() async {
    final data = await _list('workspaces');
    if (data.isEmpty && !available) return null;
    final ids = {
      for (final w in data)
        if (w['id'] is int && (w['id'] as int) >= 1 && (w['id'] as int) <= maxWorkspace) w['id'] as int,
    }.toList()
      ..sort();
    final apps = <int, List<String>>{};
    for (final c in await clients()) {
      final ws = (c['workspace'] as Map?)?['id'];
      if (ws is! int || !ids.contains(ws)) continue;
      final name = '${c['class'] ?? c['title'] ?? ''}';
      final short = name.length > 40 ? name.substring(0, 40) : name;
      if (short.isNotEmpty && !(apps[ws] ??= []).contains(short)) apps[ws]!.add(short);
    }
    int? free;
    for (var n = 1; n <= maxWorkspace; n++) {
      if (!ids.contains(n)) {
        free = n;
        break;
      }
    }
    return {
      'workspaces': [for (final id in ids) {'id': id, 'apps': apps[id] ?? const []}],
      'free': free,
    };
  }

  /// The popup (Omarchy, as the old App Manager's card): this process's
  /// window floated, sized and centred in the focused monitor's free area.
  Future<Map<String, dynamic>> placePopup(int processId, int width, int height) async {
    final g = popupGeometry(await _list('monitors'), await clients(), processId, width, height);
    if (g == null) return {'placed': false, 'reason': 'no window yet'};
    final window = "window='address:${g.address}'";
    for (final lua in [
      "hl.dsp.window.float({action='enable', $window})",
      'hl.dsp.window.resize({x=${g.width}, y=${g.height}, $window})',
      'hl.dsp.window.move({x=${g.x}, y=${g.y}, $window})',
    ]) {
      if ((await _hyprctl(['dispatch', lua]))?.trim() != 'ok') return {'placed': false, 'reason': 'dispatch failed'};
    }
    return {'placed': true, 'x': g.x, 'y': g.y, 'width': g.width, 'height': g.height};
  }
}

/// Where the popup goes: centred in the focused monitor's free area (the
/// bar's space reserved), its size kept inside it. Logical pixels.
({String address, int x, int y, int width, int height})? popupGeometry(
  List monitors,
  List clients,
  int processId,
  int width,
  int height,
) {
  final own = clients.whereType<Map>().where((c) => c['pid'] == processId && _address.hasMatch('${c['address']}')).firstOrNull;
  final monitor =
      monitors.whereType<Map>().where((m) => m['focused'] == true).firstOrNull ?? monitors.whereType<Map>().firstOrNull;
  if (own == null || monitor == null) return null;
  final scale = monitor['scale'] is num && (monitor['scale'] as num) > 0 ? (monitor['scale'] as num).toDouble() : 1.0;
  int number(Object? v) => v is num ? v.round() : 0;
  final reserved = monitor['reserved'] is List ? [for (final r in monitor['reserved'] as List) number(r)] : const <int>[];
  final pad = [...reserved, 0, 0, 0, 0];
  final left = number(monitor['x']) + pad[0], top = number(monitor['y']) + pad[1];
  final freeW = (number(monitor['width']) / scale).floor() - pad[0] - pad[2];
  final freeH = (number(monitor['height']) / scale).floor() - pad[1] - pad[3];
  const gap = 10;
  final w = width.clamp(420, freeW - 2 * gap > 420 ? freeW - 2 * gap : 420);
  final h = height.clamp(300, freeH - 2 * gap > 300 ? freeH - 2 * gap : 300);
  return (address: '${own['address']}', x: left + (freeW - w) ~/ 2, y: top + (freeH - h) ~/ 2, width: w, height: h);
}
