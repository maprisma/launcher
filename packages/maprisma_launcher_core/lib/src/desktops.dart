/// One adapter per desktop: what App Manager asks of Omarchy, GNOME, COSMIC
/// or any other XDG desktop. Picked once at start (MAPRISMA_LAUNCHER_DESKTOP wins).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'bounded.dart';
import 'desktop_entries.dart';
import 'launch.dart';
import 'origins.dart';
import 'origins.dart' as origins_lib;
import 'posix.dart';

/// The palette keys every adapter fills (palette.DEFAULT_COLORS).
const defaultColors = {
  'background': '#1e1e2e',
  'foreground': '#cdd6f4',
  'accent': '#89b4fa',
  'selection': '#45475a',
  'muted': '#888894',
  'red': '#f04452',
  'yellow': '#f9e2af',
  'orange': '#fab387',
  'green': '#a6e3a1',
};

final _color = RegExp(r'^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$');
bool isColor(Object? value) => value is String && _color.hasMatch(value.trim());

/// #rgb → #rrggbb, lower case.
String normalColor(String value) {
  final v = value.trim().toLowerCase();
  return v.length == 4 ? '#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}' : v;
}

abstract class Desktop {
  Desktop(this.session);
  final Session session;
  String get name;
  Future<Map<String, String>> themeColors();

  /// The windows' corner radius in px, or null when unknown.
  Future<int?> windowRounding();
  Future<String?> iconTheme();

  /// The sections of the "by origin" view, in order.
  List<String> get origins => const ['o-defaults', 'o-system', 'o-flatpak', 'o-user'];

  /// Where xdg-terminal-exec looks for the default terminal.
  List<String> get terminalLists => origins_lib.terminalLists(session);
  Set<String> defaultDesktops() => origins_lib.defaultDesktops(session, lists: terminalLists);
  List<String> defaultRoles(Map app) =>
      origins_lib.defaultRoles(app, session, lists: terminalLists);

  /// Which of [origins] (without "o-") an app is in.
  String origin(Map app, Set<String> defaults) => genericOrigin(app, defaults, session);
  Future<bool> launch(Map app) => launchApp(app, session, terminal: terminal());

  /// The command that updates the whole system in a window, or null:
  /// the desktop's own updater, else a terminal running the package
  /// manager's full update (an AUR helper's when there is one).
  /// The system update as it runs inside a terminal (the app's own one),
  /// or null when the desktop updates in a program of its own.
  List<String>? systemUpdateInner() {
    final line = _updateLine();
    return line == null ? null : ['sh', '-c', line];
  }

  List<String>? systemUpdate() {
    final term = terminal();
    final line = _updateLine();
    if (term == null || line == null) return null;
    return [...term, 'sh', '-c', "$line; echo; read -r -p 'Press Enter to close. ' _"];
  }

  String? _updateLine() {
    String? line;
    final helper = ['paru', 'yay'].where((h) => session.which(h) != null).firstOrNull;
    if (session.which('pacman') != null) {
      line = helper != null ? '$helper -Syu' : 'sudo pacman -Syu';
    } else if (session.which('apt') != null) {
      line = 'sudo apt update && sudo apt upgrade';
    } else if (session.which('dnf') != null) {
      line = 'sudo dnf upgrade';
    } else if (session.which('zypper') != null) {
      line = 'sudo zypper update';
    }
    return line;
  }
  List<String>? terminal() => defaultTerminal(session);

  Future<Map<String, dynamic>> look() async => {
    'desktop': name,
    // any Hyprland session (Omarchy or not): the window can be a popup there
    'hyprland': (session.environment['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty,
    'colors': await themeColors(),
    'rounding': await windowRounding(),
    'icon_theme': await iconTheme(),
  };
}

Desktop detectDesktop(Session session) {
  final env = session.environment;
  final wanted = env['MAPRISMA_LAUNCHER_DESKTOP'];
  final current = (env['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase().split(':');
  if (wanted == 'omarchy' ||
      wanted == null &&
          env['HYPRLAND_INSTANCE_SIGNATURE'] != null &&
          Directory(env['OMARCHY_PATH'] ?? '/usr/share/omarchy').existsSync()) {
    return OmarchyDesktop(session);
  }
  if (wanted == 'cosmic' || wanted == null && current.contains('cosmic')) {
    return CosmicDesktop(session);
  }
  if (wanted == 'gnome' || wanted == null && current.contains('gnome')) {
    return GnomeDesktop(session);
  }
  if (wanted == 'kde' || wanted == null && current.contains('kde')) {
    return KdeDesktop(session);
  }
  return GenericDesktop(session);
}

Future<String> _gsetting(Session session, String schema, String key) async {
  final gsettings = session.which('gsettings');
  if (gsettings == null) return '';
  final out = await readBoundedText(
    [gsettings, 'get', schema, key],
    maxBytes: 1024,
    timeout: const Duration(seconds: 2),
  );
  final text = (out ?? '').trim();
  return text.length >= 2 && text.startsWith("'") && text.endsWith("'")
      ? text.substring(1, text.length - 1)
      : text;
}

// --- Omarchy -------------------------------------------------------------------

final class OmarchyDesktop extends Desktop {
  OmarchyDesktop(super.session);
  @override
  String get name => 'omarchy';
  late final _index = OmarchyIndex(session);

  /// Packages Omarchy installs itself (removing them can break the desktop).
  Set<String> get basePackages => _index.basePackages;
  @override
  List<String> get origins => const ['o-defaults', 'o-omarchy', 'o-other'];
  @override
  String origin(Map app, Set<String> defaults) => _index.origin(app, defaults);
  @override
  List<String> get terminalLists => origins_lib.terminalLists(
    session,
    shipped: [p.join(_index.root, 'default/xdg-terminal-exec/hyprland-xdg-terminals.list')],
  );
  String get themeDir =>
      p.join(session.home, '.local/state/omarchy/current/theme');

  static const oldKeys = {
    'red': 'color1',
    'green': 'color2',
    'yellow': 'color3',
    'selection': 'selection_background',
  };

  /// desktop_omarchy.theme_colors.
  static Map<String, String> colorsFromToml(String? text) {
    Map<String, dynamic> theme;
    try {
      if (text == null) return {...defaultColors};
      theme = TomlDocument.parse(text).toMap();
    } on Object {
      return {...defaultColors};
    }
    for (final e in oldKeys.entries) {
      if (!isColor(theme[e.key]) && isColor(theme[e.value])) {
        theme[e.key] = theme[e.value];
      }
    }
    final colors = {
      for (final e in defaultColors.entries)
        e.key: isColor(theme[e.key])
            ? normalColor(theme[e.key] as String)
            : e.value,
    };
    if (!theme.containsKey('muted')) {
      colors['muted'] = [
        'dark_foreground',
        'color8',
      ].where((k) => isColor(theme[k])).map((k) => normalColor(theme[k])).firstOrNull ??
          defaultColors['muted']!;
    }
    return colors;
  }

  @override
  Future<Map<String, String>> themeColors() async {
    final bytes = Posix.instance.readRegular(
      p.join(themeDir, 'colors.toml'),
      256 * 1024,
    );
    return colorsFromToml(
      bytes == null ? null : utf8.decode(bytes, allowMalformed: true),
    );
  }

  /// corners.parse_rounding of `hyprctl getoption decoration:rounding -j`.
  static int? parseRounding(String? text) {
    try {
      final value = (jsonDecode(text ?? '') as Map)['int'];
      return value is int ? value.clamp(0, 24) : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<int?> windowRounding() async {
    final hyprctl = session.which('hyprctl');
    if (hyprctl == null) return null;
    return parseRounding(
      await readBoundedText(
        [hyprctl, 'getoption', 'decoration:rounding', '-j'],
        maxBytes: 4096,
        timeout: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Future<String?> iconTheme() async {
    final bytes = Posix.instance.readRegular(
      p.join(themeDir, 'icons.theme'),
      4096,
    );
    final own = bytes == null ? '' : utf8.decode(bytes, allowMalformed: true).trim();
    if (own.isNotEmpty) return own;
    final gtk = await _gsetting(session, 'org.gnome.desktop.interface', 'icon-theme');
    return gtk.isEmpty ? null : gtk;
  }

  @override
  Future<bool> launch(Map app) async {
    final path = app['desktop_path'] as String? ?? '';
    final uwsm = session.which('uwsm-app');
    // uwsm-app puts the app in app-graphical.slice and reads the entry itself;
    // it needs a valid desktop file id.
    if (app['argv'] == null &&
        path.isNotEmpty &&
        uwsm != null &&
        RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*\.desktop$').hasMatch(p.basename(path)) &&
        readDesktopFile(path) != null) {
      return startDetached([uwsm, '--', path], session);
    }
    return super.launch(app);
  }

  /// desktop_omarchy.system_update: Omarchy's own update window.
  @override
  List<String>? systemUpdate() {
    final launcher = session.which('omarchy-launch-floating-terminal-with-presentation');
    final update = session.which('omarchy-update');
    if (launcher == null || update == null) return super.systemUpdate();
    return [launcher, 'omarchy-update'];
  }

  @override
  List<String>? systemUpdateInner() {
    final update = session.which('omarchy-update');
    return update == null ? super.systemUpdateInner() : [update];
  }

  @override
  List<String>? terminal() {
    final xte = session.which('xdg-terminal-exec');
    return xte == null ? defaultTerminal(session) : [xte];
  }
}

// --- GNOME ---------------------------------------------------------------------

final class GnomeDesktop extends Desktop {
  GnomeDesktop(super.session);
  @override
  String get name => 'gnome';

  static const accents = {
    'blue': '#3584e4', 'teal': '#2190a4', 'green': '#3a944a',
    'yellow': '#c88800', 'orange': '#ed5b00', 'red': '#e62d42',
    'pink': '#d56199', 'purple': '#9141ac', 'slate': '#6f8396',
  };
  static const light = {
    'background': '#fafafb', 'foreground': '#323233', 'muted': '#77767b',
    'selection': '#dedddf', 'red': '#e01b24', 'yellow': '#c88800',
    'orange': '#e66100', 'green': '#26a269',
  };
  static const dark = {
    'background': '#222226', 'foreground': '#ffffff', 'muted': '#9a9996',
    'selection': '#3a3a3e', 'red': '#ff7b63', 'yellow': '#f8e45c',
    'orange': '#ffa348', 'green': '#8ff0a4',
  };

  /// desktop.theme_colors (gnome-launcher), from gsettings.
  @override
  Future<Map<String, String>> themeColors() async {
    const schema = 'org.gnome.desktop.interface';
    final isDark = await _gsetting(session, schema, 'color-scheme') == 'prefer-dark';
    final accent = accents[await _gsetting(session, schema, 'accent-color')] ??
        accents['blue']!;
    return {...(isDark ? dark : light), 'accent': accent};
  }

  @override
  Future<int?> windowRounding() async => 12;

  /// GNOME Software's update page first.
  @override
  List<String>? systemUpdate() {
    final software = session.which('gnome-software');
    return software != null ? [software, '--mode=updates'] : super.systemUpdate();
  }

  // GNOME Software updates in its own window when it is there.
  @override
  List<String>? systemUpdateInner() => session.which('gnome-software') != null ? null : super.systemUpdateInner();

  @override
  Future<String?> iconTheme() async {
    final theme = await _gsetting(session, 'org.gnome.desktop.interface', 'icon-theme');
    return theme.isEmpty ? 'Adwaita' : theme;
  }
}

// --- COSMIC --------------------------------------------------------------------

/// The value of [key] at the top level of a RON struct `( key: … , … )`.
String? ronField(String text, String key) {
  var depth = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (depth == 1 &&
        text.startsWith(key, i) &&
        (i == 0 || !RegExp(r'[\w]').hasMatch(text[i - 1]))) {
      var j = i + key.length;
      while (j < text.length && text[j] == ' ') {
        j++;
      }
      if (j >= text.length || text[j] != ':') continue;
      j++;
      final start = j;
      var d = 0;
      for (; j < text.length; j++) {
        final cj = text[j];
        if (cj == '(' || cj == '[') d++;
        if (cj == ')' || cj == ']') {
          if (d == 0) break;
          d--;
        }
        if (cj == ',' && d == 0) break;
      }
      return text.substring(start, j).trim();
    }
  }
  return null;
}

/// `(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0)` → #rrggbb.
String? ronColor(String? value) {
  if (value == null) return null;
  int? part(String name) {
    final m = RegExp('$name:\\s*([0-9.eE+-]+)').firstMatch(value);
    final v = m == null ? null : double.tryParse(m[1]!);
    return v == null ? null : (v.clamp(0, 1) * 255).round();
  }

  final r = part('red'), g = part('green'), b = part('blue');
  if (r == null || g == null || b == null) return null;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hex(r)}${hex(g)}${hex(b)}';
}

final class CosmicDesktop extends Desktop {
  /// [systemDir]: the system's default theme (tests point it elsewhere so the
  /// machine's own COSMIC theme does not leak in).
  CosmicDesktop(super.session, {this.systemDir = '/usr/share/cosmic'});
  final String systemDir;
  @override
  String get name => 'cosmic';

  String? _config(String component, String key) {
    final home = session.environment['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? session.environment['XDG_CONFIG_HOME']!
        : p.join(session.home, '.config');
    for (final base in [p.join(home, 'cosmic'), systemDir]) {
      final bytes = Posix.instance.readRegular(
        p.join(base, component, 'v1', key),
        256 * 1024,
      );
      if (bytes != null) return utf8.decode(bytes, allowMalformed: true);
    }
    return null;
  }

  bool get isDark =>
      (_config('com.system76.CosmicTheme.Mode', 'is_dark') ?? 'true').trim() != 'false';

  /// COSMIC's theme: accent, background (its base and on), and the
  /// success/warning/destructive colours. Unverified on a real COSMIC.
  @override
  Future<Map<String, String>> themeColors() async {
    final theme = isDark ? 'com.system76.CosmicTheme.Dark' : 'com.system76.CosmicTheme.Light';
    final base = {...(isDark ? GnomeDesktop.dark : GnomeDesktop.light)};
    String? container(String key, String field) {
      final text = _config(theme, key);
      return text == null ? null : ronColor(ronField(text, field));
    }

    final accent = container('accent', 'base') ?? ronColor(_config(theme, 'accent'));
    return {
      ...base,
      'accent': accent ?? '#63d0df',
      'background': ?container('background', 'base'),
      'foreground': ?container('background', 'on'),
      'green': ?container('success', 'base'),
      'yellow': ?container('warning', 'base'),
      'red': ?container('destructive', 'base'),
    };
  }

  @override
  Future<int?> windowRounding() async {
    final theme = isDark ? 'com.system76.CosmicTheme.Dark' : 'com.system76.CosmicTheme.Light';
    final radii = _config(theme, 'corner_radii');
    final small = radii == null ? null : ronField(radii, 'radius_s');
    final first = small == null
        ? null
        : RegExp(r'([0-9.]+)').firstMatch(small)?[1];
    return first == null ? 8 : double.tryParse(first)?.round() ?? 8;
  }

  @override
  Future<String?> iconTheme() async {
    final value = _config('com.system76.CosmicTk', 'icon_theme')?.trim();
    if (value == null || value.isEmpty) return 'Cosmic';
    return value.replaceAll('"', '');
  }
}

// --- KDE Plasma ------------------------------------------------------------------

/// The value of [key] in [group] of a KDE ini file (nested groups as
/// `Colors:Header][Inactive`), or null.
String? kdeIniValue(String text, String group, String key) {
  String? current, found;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1);
    } else if (current == group) {
      final eq = line.indexOf('=');
      if (eq > 0 && line.substring(0, eq).trim() == key) found = line.substring(eq + 1).trim();
    }
  }
  return found;
}

/// A KDE colour "r,g,b" (or "r,g,b,a") as #rrggbb, or null.
String? kdeColor(String? value) {
  if (value == null) return null;
  final parts = value.split(',').map((v) => int.tryParse(v.trim())).toList();
  if ((parts.length != 3 && parts.length != 4) || parts.any((v) => v == null || v < 0 || v > 255)) return null;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hex(parts[0]!)}${hex(parts[1]!)}${hex(parts[2]!)}';
}

final class KdeDesktop extends Desktop {
  KdeDesktop(super.session);
  @override
  String get name => 'kde';

  String get _kdeglobals {
    final config = session.environment['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? session.environment['XDG_CONFIG_HOME']!
        : p.join(session.home, '.config');
    final bytes = Posix.instance.readRegular(p.join(config, 'kdeglobals'), 1024 * 1024);
    return bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
  }

  static bool _dark(String hex) {
    final v = int.parse(hex.substring(1), radix: 16);
    final r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255;
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5;
  }

  /// Plasma's colour scheme as kdeglobals has it: the window for background
  /// and text, the accent (Plasma's own, else the focus decoration, else the
  /// selection), the view's negative/neutral/positive for red/yellow/green.
  @override
  Future<Map<String, String>> themeColors() async {
    final text = _kdeglobals;
    String? c(String group, String key) => kdeColor(kdeIniValue(text, group, key));
    final bg = c('Colors:Window', 'BackgroundNormal');
    final base = {...(bg == null || _dark(bg) ? GnomeDesktop.dark : GnomeDesktop.light)};
    return {
      ...base,
      'accent': c('General', 'AccentColor') ?? c('Colors:View', 'DecorationFocus') ?? c('Colors:Selection', 'BackgroundNormal') ?? '#3daee9',
      'background': ?bg,
      'foreground': ?c('Colors:Window', 'ForegroundNormal'),
      'selection': ?c('Colors:Selection', 'BackgroundNormal'),
      'muted': ?c('Colors:Window', 'ForegroundInactive'),
      'red': ?c('Colors:View', 'ForegroundNegative'),
      'yellow': ?c('Colors:View', 'ForegroundNeutral'),
      'green': ?c('Colors:View', 'ForegroundPositive'),
    };
  }

  /// Breeze's window corners.
  @override
  Future<int?> windowRounding() async => 8;

  @override
  Future<String?> iconTheme() async => kdeIniValue(_kdeglobals, 'Icons', 'Theme') ?? 'breeze';

  /// Discover's update page first.
  @override
  List<String>? systemUpdate() {
    final discover = session.which('plasma-discover');
    return discover != null ? [discover, '--mode', 'update'] : super.systemUpdate();
  }

  @override
  List<String>? systemUpdateInner() => session.which('plasma-discover') != null ? null : super.systemUpdateInner();
}

// --- Any other desktop ---------------------------------------------------------

final class GenericDesktop extends Desktop {
  GenericDesktop(super.session);
  @override
  String get name => 'generic';

  /// On Hyprland with Maprisma Shell (no Omarchy): its colour scheme
  /// (XDG_STATE_HOME/maprisma-shell/scheme.json, Material names), so the Launcher
  /// follows the theme in use, as Maprisma Settings and Playground do.
  @override
  Future<Map<String, String>> themeColors() async {
    final env = session.environment;
    final hyprland = (env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().split(':').contains('HYPRLAND');
    if (!hyprland) return {};
    final stateHome = env['XDG_STATE_HOME'];
    final state = stateHome != null && p.isAbsolute(stateHome) ? stateHome : p.join(session.home, '.local', 'state');
    final file = File(p.join(state, 'maprisma-shell', 'scheme.json'));
    Object? data;
    try {
      if (!file.existsSync() || file.lengthSync() > 256 * 1024) return {};
      data = jsonDecode(file.readAsStringSync());
    } on Object {
      return {};
    }
    final colours = data is Map ? data['colours'] : null;
    if (colours is! Map) return {};
    String? c(String key) {
      final v = colours[key];
      return v is String && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v) ? '#${v.toLowerCase()}' : null;
    }

    final out = {
      'accent': c('primary'),
      'background': c('surface') ?? c('background'),
      'foreground': c('onSurface'),
      'muted': c('outline'),
      'selection': c('surfaceContainerHighest'),
      'red': c('error') ?? c('red'),
      'yellow': c('yellow'),
      'orange': c('peach'),
      'green': c('green'),
    };
    return {for (final e in out.entries) if (e.value != null) e.key: e.value!};
  }
  /// On Hyprland: its window corners (`hyprctl -j getoption decoration:rounding`, 0–64),
  /// asked at most every 30 s (the look is re-read every few seconds); elsewhere unknown.
  @override
  Future<int?> windowRounding() async {
    final env = session.environment;
    if ((env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isEmpty) return null;
    final now = clock();
    final last = _roundingAt;
    if (last != null && now.difference(last) < roundingTtl) return _rounding;
    final hyprctl = session.which('hyprctl');
    final text = hyprctl == null
        ? null
        : await readBoundedText(
            [hyprctl, '-j', 'getoption', 'decoration:rounding'],
            maxBytes: 4096,
            timeout: const Duration(seconds: 2),
            environment: env,
          );
    _roundingAt = now;
    return _rounding = parseHyprRounding(text);
  }

  /// How long a `hyprctl` answer about the corners is kept.
  static const roundingTtl = Duration(seconds: 30);

  /// The time for [roundingTtl]; tests set their own.
  DateTime Function() clock = DateTime.now;
  DateTime? _roundingAt;
  int? _rounding;

  /// `{"int": n}` of `hyprctl -j getoption decoration:rounding` as 0–64, null when unreadable.
  static int? parseHyprRounding(String? text) {
    try {
      final value = (jsonDecode(text ?? '') as Map)['int'];
      return value is int ? value.clamp(0, 64) : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<String?> iconTheme() async {
    final theme = await _gsetting(session, 'org.gnome.desktop.interface', 'icon-theme');
    return theme.isEmpty ? null : theme;
  }
}
