/// One adapter per desktop: what App Manager asks of Omarchy, GNOME, COSMIC
/// or any other XDG desktop. Picked once at start (APPMANAGER_DESKTOP wins).
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
  List<String>? systemUpdate() {
    final term = terminal();
    if (term == null) return null;
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
    if (line == null) return null;
    return [...term, 'sh', '-c', "$line; echo; read -r -p 'Press Enter to close. ' _"];
  }
  List<String>? terminal() => defaultTerminal(session);

  Future<Map<String, dynamic>> look() async => {
    'desktop': name,
    'colors': await themeColors(),
    'rounding': await windowRounding(),
    'icon_theme': await iconTheme(),
  };
}

Desktop detectDesktop(Session session) {
  final env = session.environment;
  final wanted = env['APPMANAGER_DESKTOP'];
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
  CosmicDesktop(super.session);
  @override
  String get name => 'cosmic';

  String? _config(String component, String key) {
    final home = session.environment['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? session.environment['XDG_CONFIG_HOME']!
        : p.join(session.home, '.config');
    for (final base in [p.join(home, 'cosmic'), '/usr/share/cosmic']) {
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

// --- Any other desktop ---------------------------------------------------------

final class GenericDesktop extends Desktop {
  GenericDesktop(super.session);
  @override
  String get name => 'generic';
  @override
  Future<Map<String, String>> themeColors() async => {};
  @override
  Future<int?> windowRounding() async => null;
  @override
  Future<String?> iconTheme() async {
    final theme = await _gsetting(session, 'org.gnome.desktop.interface', 'icon-theme');
    return theme.isEmpty ? null : theme;
  }
}
