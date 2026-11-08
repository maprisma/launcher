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

/// The first keyboard layout of the session, as an XKB name ("de"), or "us".
/// Plasma's own list first (kxkbrc), then COSMIC's xkb_config, then the
/// system's (localectl: X11 config, vconsole.conf).
String detectKeyboardLayout(Map<String, String> environment) {
  final home = environment['HOME'] ?? '';
  final config = environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  String? read(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() < 64 * 1024 ? f.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  String? first(String? list) {
    final name = (list ?? '').split(',').first.trim().toLowerCase();
    return RegExp(r'^[a-z]{2,8}$').hasMatch(name) ? name : null;
  }

  final kxkb = read('$config/kxkbrc');
  if (kxkb != null) {
    final m = RegExp(r'^LayoutList=(.*)$', multiLine: true).firstMatch(kxkb);
    final name = first(m?[1]);
    if (name != null) return name;
  }
  final cosmic = read('$config/cosmic/com.system76.CosmicComp/v1/xkb_config');
  if (cosmic != null) {
    final name = first(RegExp(r'layout:\s*"([^"]*)"').firstMatch(cosmic)?[1]);
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
