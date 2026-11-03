/// "Open as administrator" (reference/gnome-launcher launcher_core: the
/// session-bound opt-in admin_action_enabled / set_admin_action /
/// session_token, admin_command, allow_root_on_display). Off by default;
/// switched on only after polkit confirmed the password, and only for the
/// login session that did it. Graphical apps go through pkexec with display
/// and look variables only; terminal apps run sudo inside a terminal; Files
/// opens admin:/// as the user. Nothing goes through a shell.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'posix.dart';
import 'shlex.dart';

const adminFlagName = 'maprisma-launcher-admin-action';
const adminDisplayVars = ['XDG_SESSION_TYPE', 'DISPLAY', 'XAUTHORITY'];
const adminLookVars = [
  'GDK_SCALE', 'GDK_DPI_SCALE', 'QT_SCALE_FACTOR', 'QT_QPA_PLATFORMTHEME', 'QT_STYLE_OVERRIDE', 'GTK_THEME',
  'XCURSOR_THEME', 'XCURSOR_SIZE',
];
const adminRefusedPrograms = {'flatpak', 'snap', 'xdg-open', 'gtk-launch'};
const adminTerminals = {'foot', 'footclient', 'alacritty', 'ghostty', 'xterm', 'xdg-terminal-exec'};
const _terminals = {
  'foot', 'footclient', 'alacritty', 'kitty', 'ghostty', 'wezterm', 'xterm', 'ptyxis', 'kgx', 'gnome-terminal',
  'gnome-terminal-server', 'konsole',
};
const adminUriApps = {'nautilus': 'admin:///'};
const gvfsAdminBackends = ['/usr/lib/gvfsd-admin', '/usr/lib/gvfs/gvfsd-admin', '/usr/libexec/gvfsd-admin'];

final class Admin {
  Admin(this.session, {this.sessionsDir = '/run/systemd/sessions', this.bootIdFile = '/proc/sys/kernel/random/boot_id'});
  final Session session;
  final String sessionsDir, bootIdFile;
  Map<String, String> get env => session.environment;

  /// _session_dir: $XDG_RUNTIME_DIR when it is a private folder of ours.
  String? sessionDir() {
    final runtime = env['XDG_RUNTIME_DIR'] ?? '';
    if (runtime.isEmpty || !p.isAbsolute(runtime)) return null;
    try {
      final stat = FileStat.statSync(runtime);
      if (stat.type != FileSystemEntityType.directory || FileSystemEntity.isLinkSync(runtime)) return null;
      if (Posix.instance.ownerOf(runtime) != Posix.instance.uid || stat.mode & 0x3f != 0) return null;
    } on FileSystemException {
      return null;
    }
    return runtime;
  }

  /// session_token: this boot, this login session and its start, from
  /// systemd-logind's root-owned record (removed at logout).
  String? sessionToken() {
    final sid = env['XDG_SESSION_ID'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9]{1,32}$').hasMatch(sid)) return null;
    final record = p.join(sessionsDir, sid);
    if (FileSystemEntity.typeSync(record, followLinks: false) != FileSystemEntityType.file) return null;
    if (Posix.instance.ownerOf(record) != 0) return null;
    final bytes = Posix.instance.readRegular(record, 64 * 1024, follow: false);
    final boot = Posix.instance.readRegular(bootIdFile, 64);
    if (bytes == null || boot == null) return null;
    final fields = <String, String>{
      for (final line in utf8.decode(bytes, allowMalformed: true).split('\n'))
        if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
    };
    final bootId = ascii.decode(boot, allowInvalid: true).trim();
    if (fields['UID'] != '${Posix.instance.uid}' || !const ['active', 'online'].contains(fields['STATE'])) return null;
    final started = fields['REALTIME'] ?? '';
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(started) || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(bootId)) return null;
    return '$bootId:$sid:$started';
  }

  bool enabled() {
    final dir = sessionDir(), token = sessionToken();
    if (dir == null || token == null) return false;
    final flag = p.join(dir, adminFlagName);
    if (Posix.instance.ownerOf(flag) != Posix.instance.uid) return false;
    final bytes = Posix.instance.readRegular(flag, 256, follow: false);
    return bytes != null && ascii.decode(bytes, allowInvalid: true).trim() == token;
  }

  /// set_admin_action: the marker, written privately; off removes it.
  void setEnabled(bool on) {
    final dir = sessionDir();
    final flag = dir == null ? null : p.join(dir, adminFlagName);
    if (!on) {
      if (flag != null) {
        try {
          File(flag).deleteSync();
        } on FileSystemException {
          // not there
        }
      }
      return;
    }
    final token = sessionToken();
    if (flag == null || token == null) {
      throw const FileSystemException('no private session folder or login session to tie the setting to');
    }
    final tmp = p.join(dir!, '.$adminFlagName.$pid.tmp');
    try {
      File(tmp).deleteSync();
    } on FileSystemException {
      // none
    }
    if (!Posix.instance.writeNewPrivate(tmp, ascii.encode(token))) {
      throw FileSystemException('Could not write', flag);
    }
    File(tmp).renameSync(flag);
  }

  /// The password check before switching on: polkit runs only /usr/bin/true.
  Future<bool> confirmPassword() async {
    final pkexec = session.which('pkexec');
    if (pkexec == null || !Posix.instance.executable('/usr/bin/true')) return false;
    final out = await readBoundedText([pkexec, '/usr/bin/true'],
        timeout: const Duration(minutes: 3), environment: session.environment);
    return out != null;
  }

  /// _admin_command: the app's own argv, or null when nothing can run as root.
  List<String>? _ownArgv(Map app) {
    if (app['argv'] case final List argv) return [for (final a in argv) '$a'];
    if ((app['desktop_path'] as String? ?? '').isEmpty || app['sandboxed'] == true || app['pwa'] == true) return null;
    List<String> argv;
    try {
      argv = shlexSplit(app['exec'] as String? ?? '');
    } on FormatException {
      return null;
    }
    if (argv.isEmpty) return null;
    final program = p.basename(argv.first);
    if (adminRefusedPrograms.contains(program) || argv.first.startsWith('/snap/')) return null;
    if (webAppBrowsers.containsKey(program) && argv.any((a) => a.startsWith('--app=') || a.startsWith('--app-id='))) {
      return null; // A browser opened as a web app window.
    }
    return argv;
  }

  bool usesElectron(String program) {
    if (webAppBrowsers.containsKey(p.basename(program))) return true;
    try {
      final path = File(program).resolveSymbolicLinksSync();
      final folder = p.dirname(path);
      if (FileSystemEntity.typeSync(p.join(folder, 'chrome-sandbox')) != FileSystemEntityType.notFound ||
          FileSystemEntity.typeSync(p.join(folder, 'resources', 'app.asar')) != FileSystemEntityType.notFound) {
        return true;
      }
      final file = File(path).openSync();
      try {
        final head = file.readSync(4096);
        return head.length >= 2 && head[0] == 0x23 && head[1] == 0x21 &&
            latin1.decode(head).toLowerCase().contains('electron');
      } finally {
        file.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  Future<String> _gsetting(String key) async {
    final gsettings = session.which('gsettings');
    if (gsettings == null) return '';
    final out = await readBoundedText([gsettings, 'get', 'org.gnome.desktop.interface', key],
        maxBytes: 4096, timeout: const Duration(seconds: 2), environment: session.environment);
    var value = (out ?? '').trim();
    value = value.replaceAll(RegExp(r"^'+|'+$"), '');
    return RegExp(r'^[\w.+-]{1,64}$').hasMatch(value) ? value : '';
  }

  /// _desktop_look: the user's GTK theme, dark mode for GTK and libadwaita.
  Future<Map<String, String>> _desktopLook() async {
    final out = <String, String>{};
    final dark = await _gsetting('color-scheme') == 'prefer-dark';
    if ((env['GTK_THEME'] ?? '').isEmpty) {
      final theme = await _gsetting('gtk-theme');
      if (theme.isNotEmpty) out['GTK_THEME'] = dark && !theme.toLowerCase().contains('dark') ? '$theme:dark' : theme;
    }
    if (dark) out['ADW_DEBUG_COLOR_SCHEME'] = 'prefer-dark';
    return out;
  }

  String? _displayScale() {
    final value = double.tryParse(env['GDK_SCALE'] ?? '');
    if (value == null || value < 0.5 || value > 4 || value == 1) return null;
    final text = value.toString();
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  bool canAdmitRootOnDisplay() => (env['DISPLAY'] ?? '').isNotEmpty && _libX11() != null;

  /// admin_command: the argv that opens the app as root, or null.
  Future<List<String>?> command(Map app) async {
    if (Posix.instance.uid == 0) return null;
    final argv = _ownArgv(app);
    if (argv == null) return null;
    final first = p.basename(argv.first).toLowerCase();
    if (_terminals.contains(first) || adminTerminals.contains(first)) {
      if (!adminTerminals.contains(first) || session.which('sudo') == null) return null;
      final at = argv.indexOf('-e');
      if (at < 0) return [...argv, '-e', 'sudo', '-i'];
      if (at + 1 >= argv.length) return null;
      argv[at + 1] = session.which(argv[at + 1]) ?? argv[at + 1];
      return [...argv.sublist(0, at + 1), 'sudo', '--', ...argv.sublist(at + 1)];
    }
    if (app['terminal'] == true) {
      if (session.which('xdg-terminal-exec') == null || session.which('sudo') == null) return null;
      return ['xdg-terminal-exec', 'sudo', '--', session.which(argv.first) ?? argv.first, ...argv.sublist(1)];
    }
    final program = session.which(argv.first);
    if (program != null && adminUriApps.containsKey(p.basename(program))) {
      if (!gvfsAdminBackends.any((b) => File(b).existsSync())) return null;
      return [program, '--new-window', adminUriApps[p.basename(program)]!];
    }
    if (program == null || session.which('pkexec') == null) return null;
    argv[0] = program; // pkexec runs with root's PATH.
    final vars = <String>[];
    var wayland = env['WAYLAND_DISPLAY'] ?? '';
    final runtime = env['XDG_RUNTIME_DIR'] ?? '';
    if (wayland.isNotEmpty && !wayland.startsWith('/') && runtime.isNotEmpty) wayland = p.join(runtime, wayland);
    if (wayland.startsWith('/')) vars.add('WAYLAND_DISPLAY=$wayland');
    if (usesElectron(program)) {
      if (!argv.contains('--no-sandbox')) argv.add('--no-sandbox');
      if (!argv.any((a) => a.startsWith('--ozone-platform'))) {
        if (canAdmitRootOnDisplay()) {
          argv.add('--ozone-platform=x11');
          final scale = _displayScale();
          if (scale != null && !argv.any((a) => a.startsWith('--force-device-scale-factor'))) {
            argv.add('--force-device-scale-factor=$scale');
          }
        } else if (wayland.startsWith('/')) {
          argv.add('--ozone-platform-hint=auto');
        }
      }
    }
    for (final name in adminDisplayVars) {
      if ((env[name] ?? '').isNotEmpty) vars.add('$name=${env[name]}');
    }
    if (vars.isEmpty) return null; // No display to open a window on.
    final look = <String, String>{
      for (final name in adminLookVars)
        if ((env[name] ?? '').isNotEmpty) name: env[name]!,
      ...await _desktopLook(),
    };
    vars.addAll([for (final e in look.entries) '${e.key}=${e.value}']);
    return ['pkexec', 'env', ...vars, ...argv];
  }

  /// allow_root_on_display: root, and only root, may open windows on this
  /// session's X display (`xhost +si:localuser:root` without xhost); until logout.
  bool allowRootOnDisplay() {
    final lib = _libX11();
    final name = env['DISPLAY'] ?? '';
    if (lib == null || name.isEmpty) return false;
    final errors = <int>[];
    final handler = NativeCallable<Int Function(Pointer<Void>, Pointer<Void>)>.isolateLocal(
      (Pointer<Void> d, Pointer<Void> e) {
        errors.add(1);
        return 0;
      },
      exceptionalReturn: 0,
    );
    final setHandler = lib.lookupFunction<Pointer<Void> Function(Pointer<NativeFunction<Int Function(Pointer<Void>, Pointer<Void>)>>),
        Pointer<Void> Function(Pointer<NativeFunction<Int Function(Pointer<Void>, Pointer<Void>)>>)>('XSetErrorHandler');
    final open = lib.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('XOpenDisplay');
    final addHost = lib.lookupFunction<Int Function(Pointer<Void>, Pointer<Uint8>), int Function(Pointer<Void>, Pointer<Uint8>)>('XAddHost');
    final sync = lib.lookupFunction<Int Function(Pointer<Void>, Int), int Function(Pointer<Void>, int)>('XSync');
    final close = lib.lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>('XCloseDisplay');
    final previous = setHandler(handler.nativeFunction);
    final displayName = name.toNativeUtf8();
    final type = 'localuser'.toNativeUtf8(), value = 'root'.toNativeUtf8();
    // XServerInterpretedAddress {int typelength, valuelength; char *type, *value}
    final si = calloc<Uint8>(24);
    // XHostAddress {int family; int length; char *address}
    final host = calloc<Uint8>(16);
    try {
      final display = open(displayName);
      if (display == nullptr) return false;
      try {
        final s = si.cast<Int32>();
        s[0] = 9;
        s[1] = 4;
        (si + 8).cast<Pointer<Utf8>>().value = type;
        (si + 16).cast<Pointer<Utf8>>().value = value;
        final h = host.cast<Int32>();
        h[0] = 5; // FamilyServerInterpreted
        h[1] = 24;
        (host + 8).cast<Pointer<Uint8>>().value = si;
        addHost(display, host);
        sync(display, 0);
        return errors.isEmpty;
      } finally {
        close(display);
      }
    } finally {
      setHandler(previous.cast());
      handler.close();
      calloc.free(displayName);
      calloc.free(type);
      calloc.free(value);
      calloc.free(si);
      calloc.free(host);
    }
  }

  static DynamicLibrary? _x11;
  static DynamicLibrary? _libX11() {
    try {
      return _x11 ??= DynamicLibrary.open('libX11.so.6');
    } on ArgumentError {
      return null;
    }
  }

  /// launch_as_admin.
  Future<bool> launch(Map app) async {
    final argv = await command(app);
    if (argv == null) return false;
    if (argv.contains('--ozone-platform=x11')) allowRootOnDisplay();
    final full = [session.which(argv.first) ?? argv.first, ...argv.sublist(1)];
    try {
      await Process.start(full.first, full.sublist(1),
          mode: ProcessStartMode.detached, environment: session.environment, includeParentEnvironment: false);
      return true;
    } on ProcessException {
      return false;
    }
  }
}
