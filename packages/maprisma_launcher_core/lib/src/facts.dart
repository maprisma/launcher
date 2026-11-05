/// What an app is, for cards and Details (reference details.py app_facts,
/// package_info), without a process per app: one `pacman -Qo` for all
/// programs and desktop files, pacman's local database read directly, one
/// `flatpak list` for all Flatpaks, the file size of AppImages.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'appimage_updates.dart';
import 'desktop_entries.dart';
import 'origins.dart';
import 'posix.dart';
import 'updates.dart';

const pacmanDb = '/var/lib/pacman/local';
const maxDescBytes = 256 * 1024;
final packageNameRe = RegExp(r'^[A-Za-z0-9@._+-]{1,128}$');

/// details.parse_desc: %NAME%\nvalue\n… blocks.
Map<String, String> parseDesc(String text) {
  final fields = <String, List<String>>{};
  String? key;
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('%') && line.endsWith('%') && line.length > 2) {
      key = line.replaceAll(RegExp(r'^%+|%+$'), '');
      fields[key] = [];
    } else if (key != null && line.isNotEmpty) {
      fields[key]!.add(line);
    } else if (line.isEmpty) {
      key = null;
    }
  }
  return {for (final e in fields.entries) e.key: e.value.join('\n')};
}

/// pacman's local database: package name → its facts, read once per change.
final class PacmanDb {
  PacmanDb({this.root = pacmanDb});
  final String root;
  String? _stamp;
  Map<String, Map<String, dynamic>> _packages = const {};

  Map<String, Map<String, dynamic>> get packages {
    String? stamp;
    try {
      stamp = '${Directory(root).statSync().modified.microsecondsSinceEpoch}';
    } on FileSystemException {
      return const {};
    }
    if (stamp == _stamp) return _packages;
    final out = <String, Map<String, dynamic>>{};
    List<FileSystemEntity> dirs;
    try {
      dirs = Directory(root).listSync();
    } on FileSystemException {
      dirs = const [];
    }
    for (final dir in dirs) {
      final bytes = Posix.instance.readRegular(
        p.join(dir.path, 'desc'),
        maxDescBytes,
      );
      if (bytes == null) continue;
      final f = parseDesc(utf8.decode(bytes, allowMalformed: true));
      final name = f['NAME'];
      if (name == null || !packageNameRe.hasMatch(name)) continue;
      out[name] = {
        'name': name,
        'version': f['VERSION'] ?? '',
        'url': f['URL'] ?? '',
        'description': f['DESC'] ?? '',
        'size': ?int.tryParse(f['SIZE'] ?? ''),
        'installed': ?int.tryParse(f['INSTALLDATE'] ?? ''),
        'built': ?int.tryParse(f['BUILDDATE'] ?? ''),
      };
    }
    _stamp = stamp;
    return _packages = out;
  }
}

/// flatpak's `--columns=application,version,size,description` (tab separated).
Map<String, Map<String, String>> parseFlatpakFacts(String? text) => {
  for (final line in (text ?? '').split('\n'))
    if (line.split('\t') case [
      final id,
      final version,
      final size,
      final description,
      ...,
    ] when flatpakIdRe.hasMatch(id))
      id: {
        'version': version.trim(),
        'size_text': size.trim(),
        'description': description.trim(),
      },
};

final class AppFacts {
  AppFacts(this.session);
  final Session session;
  final db = PacmanDb();
  Map<String, Map<String, dynamic>>? _cache;
  String? _cacheStamp;

  void invalidate() => _cache = null;

  String _stamp(List<Map> apps) {
    String m(String path) {
      try {
        return '${FileStat.statSync(path).modified.microsecondsSinceEpoch}';
      } on Object {
        return '-';
      }
    }

    return [
      apps.length,
      m(pacmanDb),
      m('/var/lib/flatpak/app'),
      m(p.join(session.home, '.local/share/flatpak/app')),
    ].join(':');
  }

  /// {key: facts} for every app: kind, manager, package facts or file size.
  Future<Map<String, Map<String, dynamic>>> all(Map<String, Map> apps) async {
    final stamp = _stamp(apps.values.toList());
    if (_cache != null && stamp == _cacheStamp) return _cache!;
    final programs = {
      for (final e in apps.entries) e.key: programPath(e.value, session),
    };
    final owned = <String>{
      for (final path in programs.values)
        if (path != null && path.startsWith('/')) path,
      for (final app in apps.values)
        if ((app['desktop_path'] as String? ?? '').startsWith('/usr/'))
          app['desktop_path'] as String,
    };
    final owners = await _owners(owned);
    final packages = db.packages;
    final flatpaks = await _flatpaks();
    final out = <String, Map<String, dynamic>>{};
    for (final e in apps.entries) {
      final app = e.value;
      final plan = uninstallPlan(app, session);
      final address = webAddress(app);
      final facts = <String, dynamic>{
        'kind': app['argv'] != null && (app['desktop_path'] ?? '') == ''
            ? (app['cli_command'] != null ? 'cli' : 'appimage')
            : app['sandboxed'] == true
            ? 'flatpak'
            : app['pwa'] == true || address != null
            ? 'webapp'
            : app['terminal'] == true ||
                  terminalProgram(commandArgv(app)) != null
            ? 'terminal'
            : 'app',
        'program': ?programs[e.key],
        'website': ?address,
      };
      if (programs[e.key] case final program?
          when program.toLowerCase().endsWith('.appimage')) {
        final record = AppImageUpdates(session).installedRecord(program);
        facts['version'] = record == null ? appImageVersion(program) : record.version;
        if (record != null && record.version == null) facts['version_unknown'] = true;
      }
      if (plan case ('flatpak', final id?)) {
        facts['manager'] = 'flatpak';
        facts['package'] = {'name': id, ...?flatpaks[id]};
      } else {
        // The program's owner first (details.app_facts), else the desktop file's.
        final owner = owners[programs[e.key]] ?? owners[app['desktop_path']];
        // The package that installed the entry itself (not only its program:
        // a web app's program is the browser, a CLI's maybe node).
        if (owners[app['desktop_path']] case final own?) {
          facts['desktop_package'] = own;
        }
        final info = owner == null ? null : packages[owner];
        if (info != null) {
          facts['manager'] = 'pacman';
          facts['package'] = info;
        } else if (programs[e.key] case final program? when address == null) {
          try {
            final stat = File(program).statSync();
            facts['file_size'] = stat.size;
            facts['modified'] = stat.modified.millisecondsSinceEpoch ~/ 1000;
          } on FileSystemException {
            // No size then.
          }
        }
      }
      out[e.key] = facts;
    }
    _cacheStamp = stamp;
    return _cache = out;
  }

  Future<Map<String, String>> _owners(Set<String> paths) async {
    final pacman = session.which('pacman');
    if (paths.isEmpty || pacman == null) return {};
    // One call for all; exit 1 when some path has no owner.
    return parseOwnerLines(
      await readBoundedText(
        [pacman, '-Qo', '--', ...paths.take(4000)],
        maxBytes: 1024 * 1024,
        timeout: const Duration(seconds: 20),
        // pacman -Qo exits with the number of paths it found no owner for.
        okCodes: const {},
        environment: {...session.environment, 'LC_ALL': 'C'},
      ),
    );
  }

  Future<Map<String, Map<String, String>>> _flatpaks() async {
    final flatpak = session.which('flatpak');
    if (flatpak == null) return {};
    return parseFlatpakFacts(
      await readBoundedText(
        [
          flatpak,
          'list',
          '--app',
          '--columns=application,version,size,description',
        ],
        maxBytes: 1024 * 1024,
        timeout: const Duration(seconds: 20),
        environment: session.environment,
      ),
    );
  }
}
