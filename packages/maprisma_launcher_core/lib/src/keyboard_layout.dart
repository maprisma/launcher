import 'dart:io';

/// The key map's rows per keyboard layout (keysym names: what GNOME
/// accelerators, COSMIC, Hyprland and KDE's Qt codes are made from). The
/// rows follow the physical keyboard, so the map looks like the keys under
/// the user's fingers; a layout without its own rows uses US.
const usKeyRows = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'minus', 'equal'],
  ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'bracketleft', 'bracketright'],
  ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'semicolon', 'apostrophe', 'backslash'],
  ['grave', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 'comma', 'period', 'slash'],
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
  // launcher.py OTHER_KEYS, then the navigation keys.
  ['Return', 'space', 'BackSpace', 'Delete', 'Home', 'End', 'Page_Up', 'Page_Down', 'Insert', 'Tab'],
];

/// German (de, also Austria): QWERTZ with ß, ü, +, ö, ä, # and < on their
/// own keys; the US symbols there need AltGr and are left out.
const deKeyRows = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'ssharp'],
  ['Q', 'W', 'E', 'R', 'T', 'Z', 'U', 'I', 'O', 'P', 'udiaeresis', 'plus'],
  ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'odiaeresis', 'adiaeresis', 'numbersign'],
  ['less', 'Y', 'X', 'C', 'V', 'B', 'N', 'M', 'comma', 'period', 'minus'],
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
  ['Return', 'space', 'BackSpace', 'Delete', 'Home', 'End', 'Page_Up', 'Page_Down', 'Insert', 'Tab'],
];

const keyRowsByLayout = {'us': usKeyRows, 'de': deKeyRows, 'at': deKeyRows};

/// The rows for [layout] (an XKB layout name), US for others.
List<List<String>> keyRowsFor(String layout) => keyRowsByLayout[layout] ?? usKeyRows;

/// The session's keyboard layout as an XKB name ("de"), or "us". Plasma:
/// its layout list (kxkbrc), the one in use when there are several (asked
/// over D-Bus through [kdeLayoutIndex]); COSMIC: its xkb_config; then the
/// system's (localectl's files), which both use when they have no list.
String detectKeyboardLayout(Map<String, String> environment, {int? Function()? kdeLayoutIndex}) {
  final home = environment['HOME'] ?? '';
  final config = environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  final desktop = (environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase();
  String? read(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() < 64 * 1024 ? f.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  String? valid(String? name) {
    final n = (name ?? '').trim().toLowerCase();
    return RegExp(r'^[a-z]{2,8}$').hasMatch(n) ? n : null;
  }

  String? first(String? list) => valid((list ?? '').split(',').first);

  if (desktop.contains('KDE')) {
    final kxkb = read('$config/kxkbrc');
    final list = kxkb == null ? null : RegExp(r'^LayoutList=(.*)$', multiLine: true).firstMatch(kxkb)?[1];
    final names = [for (final n in (list ?? '').split(',')) ?valid(n)];
    if (names.length > 1) {
      final i = (kdeLayoutIndex ?? _kdeLayoutIndex)();
      if (i != null && i >= 0 && i < names.length) return names[i];
    }
    if (names.isNotEmpty) return names.first;
  } else if (desktop.contains('COSMIC')) {
    final cosmic = read('$config/cosmic/com.system76.CosmicComp/v1/xkb_config');
    final name = first(RegExp(r'layout:\s*"([^"]*)"').firstMatch(cosmic ?? '')?[1]);
    if (name != null) return name;
  }
  final x11 = read('/etc/X11/xorg.conf.d/00-keyboard.conf');
  if (x11 != null) {
    final name = first(RegExp(r'Option\s+"XkbLayout"\s+"([^"]*)"').firstMatch(x11)?[1]);
    if (name != null) return name;
  }
  final vconsole = read('/etc/vconsole.conf');
  if (vconsole != null) {
    final m = RegExp(r'^XKBLAYOUT=(.*)$', multiLine: true).firstMatch(vconsole) ??
        RegExp(r'^KEYMAP=([a-z]+)', multiLine: true).firstMatch(vconsole);
    final name = first(m?[1]?.replaceAll('"', ''));
    if (name != null) return name;
  }
  return 'us';
}

/// Plasma's layout in use (an index into its list), or null.
int? _kdeLayoutIndex() {
  try {
    final r = Process.runSync('qdbus6', ['org.kde.keyboard', '/Layouts', 'org.kde.KeyboardLayouts.getLayout']);
    return r.exitCode == 0 ? int.tryParse('${r.stdout}'.trim()) : null;
  } on ProcessException {
    return null;
  }
}
