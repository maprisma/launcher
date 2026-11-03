/// Which apps have updates (reference updates.py) and how an app is
/// uninstalled (details.uninstall_plan).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';

final _updateLine = RegExp(r'^([A-Za-z0-9@._+-]{1,128}) (\S{1,64}) -> (\S{1,64})$');
final _flatpakLine = RegExp(r'^([A-Za-z][A-Za-z0-9_.-]{2,254})\t(\S{0,64})$');
final _ownerLine = RegExp(r'^(/.{1,1024}) is owned by ([A-Za-z0-9@._+-]{1,128}) \S{1,64}$');
final flatpakIdRe = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$');
const maxDesktopFiles = 2000;

/// {package: (installed, available)} from checkupdates / yay -Qua output.
Map<String, (String, String)> parseUpdateLines(String? text) => {
  for (final line in (text ?? '').split('\n'))
    if (_updateLine.firstMatch(line.trim()) case final m?) m[1]!: (m[2]!, m[3]!),
};

Map<String, String> parseOwnerLines(String? text) => {
  for (final line in (text ?? '').split('\n'))
    if (_ownerLine.firstMatch(line.trim()) case final m?) m[1]!: m[2]!,
};

/// {app id: version} from flatpak's `--columns=application,version`.
Map<String, String> parseFlatpakLines(String? text) => {
  for (final line in (text ?? '').split('\n'))
    if (_flatpakLine.firstMatch(line.replaceAll(RegExp(r'\n$'), '')) case final m?) m[1]!: m[2]!,
};

final class UpdateCheck {
  UpdateCheck(this.session);
  final Session session;
  Map<String, String> get _cEnv => {...session.environment, 'LC_ALL': 'C'};

  Future<Map<String, (String, String)>> packageUpdates() async {
    final result = <String, (String, String)>{};
    final check = session.which('checkupdates');
    if (check != null) {
      // Exit 2: no updates. checkupdates syncs a private copy of the database.
      result.addAll(parseUpdateLines(await readBoundedText(
        [check],
        maxBytes: 1024 * 1024,
        timeout: const Duration(seconds: 90),
        okCodes: const {0, 2},
        environment: session.environment,
      )));
    }
    for (final helper in ['yay', 'paru']) {
      final path = session.which(helper);
      if (path == null) continue;
      // Exit 1: no AUR updates.
      result.addAll(parseUpdateLines(await readBoundedText(
        [path, '-Qua'],
        maxBytes: 1024 * 1024,
        timeout: const Duration(seconds: 90),
        okCodes: const {0, 1},
        environment: session.environment,
      )));
      break;
    }
    return result;
  }

  /// {.desktop path: owning package} for the system-wide desktop files.
  Future<Map<String, String>> desktopPackages(Iterable<String> paths) async {
    final wanted = {
      for (final path in paths)
        if (path.startsWith('/usr/') && path.endsWith('.desktop')) path,
    }.take(maxDesktopFiles).toList();
    final pacman = session.which('pacman');
    if (wanted.isEmpty || pacman == null) return {};
    // Exit 1 when some file has no owner; the others are still listed.
    return parseOwnerLines(await readBoundedText(
      [pacman, '-Qo', '--', ...wanted],
      maxBytes: 1024 * 1024,
      timeout: const Duration(seconds: 20),
      okCodes: const {0, 1},
      environment: _cEnv,
    ));
  }

  /// {app id: (installed, available)} for Flatpak apps with an update.
  Future<Map<String, (String, String)>> flatpakUpdates() async {
    final flatpak = session.which('flatpak');
    if (flatpak == null) return {};
    const columns = ['--app', '--columns=application,version'];
    final available = parseFlatpakLines(await readBoundedText(
      [flatpak, 'remote-ls', '--updates', ...columns],
      maxBytes: 1024 * 1024,
      timeout: const Duration(seconds: 90),
      environment: session.environment,
    ));
    if (available.isEmpty) return {};
    final installed = parseFlatpakLines(await readBoundedText(
      [flatpak, 'list', ...columns],
      maxBytes: 1024 * 1024,
      timeout: const Duration(seconds: 20),
      environment: session.environment,
    ));
    return {for (final e in available.entries) e.key: (installed[e.key] ?? '', e.value)};
  }

  /// updates.check: {"apps": {path: (package, installed, available)},
  /// "flatpaks": {app id: (installed, available)}}.
  Future<Map<String, dynamic>> check(Iterable<String> desktopPaths, {bool fetch = true}) async {
    final owners = await desktopPackages(desktopPaths);
    final packages = owners.isEmpty ? <String, (String, String)>{} : await packageUpdates();
    return {
      'apps': {
        for (final e in owners.entries)
          if (packages[e.value] case final v?) e.key: [e.value, v.$1, v.$2],
      },
      'flatpaks': fetch
          ? {for (final e in (await flatpakUpdates()).entries) e.key: [e.value.$1, e.value.$2]}
          : <String, dynamic>{},
    };
  }

  /// `flatpak update -y <app id>`: one Flatpak app on its own. (ok, message).
  Future<(bool, String)> runFlatpakUpdate(String appId) async {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{2,254}$').hasMatch(appId) || appId.contains('..')) {
      return (false, 'invalid app id');
    }
    final flatpak = session.which('flatpak');
    if (flatpak == null) return (false, 'no flatpak');
    final out = await readBoundedText(
      [flatpak, 'update', '-y', '--noninteractive', appId],
      maxBytes: 64 * 1024,
      timeout: const Duration(seconds: 600),
      environment: _cEnv,
    );
    return out == null ? (false, 'flatpak update failed') : (true, '');
  }
}

/// details.uninstall_plan without asking pacman (look_up_package=False):
/// ("webapp", browser) | ("flatpak", id) | ("package", null) | ("trash", path) | null.
(String, String?)? uninstallPlan(Map app, Session session) {
  if (app['cli_command'] != null) return null;
  final browser = browserWebApp(app);
  if (browser != null) return ('webapp', browser);
  final desktopPath = app['desktop_path'] as String? ?? '';
  if (app['sandboxed'] == true && desktopPath.contains('/flatpak/')) {
    final id = p.basename(desktopPath).replaceFirst(RegExp(r'\.desktop$'), '');
    return flatpakIdRe.hasMatch(id) ? ('flatpak', id) : null;
  }
  if (desktopPath.isEmpty) {
    final argv = app['argv'];
    if (argv is List && argv.length == 1 && p.isAbsolute('${argv[0]}') && FileSystemEntity.isFileSync('${argv[0]}')) {
      return ('trash', '${argv[0]}');
    }
    return null;
  }
  final env = session.environment;
  final userData = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : p.join(session.home, '.local/share');
  try {
    final real = File(desktopPath).resolveSymbolicLinksSync();
    final own = Directory(p.join(userData, 'applications')).resolveSymbolicLinksSync();
    if (p.isWithin(own, real)) return ('trash', desktopPath);
  } on FileSystemException {
    // Not resolvable: a package.
  }
  return ('package', null);
}
