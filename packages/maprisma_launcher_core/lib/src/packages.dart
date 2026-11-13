/// Package managers: which are there, searching them, and the commands that
/// install or remove a package (docs/proposals/ask-ai.md, step 1). Commands
/// run in a terminal (sudo asks there), the package name is a positional
/// argument ("$1"), never part of the shell text; AUR helpers run without
/// --noconfirm, so their own review stays.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'updates.dart';

/// id, label, the programs that make it available.
const managerKinds = [
  ('pacman', 'pacman', ['pacman']),
  ('aur', 'AUR', ['yay', 'paru']),
  ('flatpak', 'Flatpak', ['flatpak']),
  ('snap', 'Snap', ['snap']),
  ('apt', 'apt', ['apt-get']),
  ('dnf', 'dnf', ['dnf']),
  ('zypper', 'zypper', ['zypper']),
];

const maxResultsPerManager = 25;
final _pkg = RegExp(r'^[A-Za-z0-9@._+:-]{1,200}$');
bool validPackage(String name) => _pkg.hasMatch(name) && !name.startsWith('-');

/// A found package. [installed]: already on this system.
typedef Found = Map<String, dynamic>;

final class Managers {
  Managers(this.session);
  final Session session;

  /// {id: program} for the managers on this system (the AUR helper: yay or paru).
  Map<String, String> installed() => {
    for (final (id, _, programs) in managerKinds) id: ?programs.map(session.which).whereType<String>().firstOrNull,
  };

  /// The default choice: every installed one but the AUR (Antigravity's
  /// review, point 6a: community build scripts are a deliberate choice).
  List<String> defaults() => [for (final id in installed().keys) if (id != 'aur') id];

  /// Search the enabled managers; official repositories come first.
  Future<List<Found>> search(String query, List<String> enabled) async {
    final there = installed();
    final out = <Found>[];
    for (final (id, _, _) in managerKinds) {
      final program = there[id];
      if (program == null || !enabled.contains(id)) continue;
      final found = await _search(id, program, query);
      out.addAll(found.take(maxResultsPerManager));
    }
    return out;
  }

  static String _regexEscape(String text) => text.replaceAllMapped(RegExp(r'[\\^$.|?*+()\[\]{}]'), (m) => '\\${m[0]}');

  Future<List<Found>> _search(String id, String program, String query) async {
    Future<String?> run(List<String> args, {Set<int> ok = const {0}}) => readBoundedText(
      [program, ...args],
      maxBytes: 2 * 1024 * 1024,
      timeout: const Duration(seconds: 30),
      okCodes: ok,
      environment: {...session.environment, 'LC_ALL': 'C'},
    );
    // Exit 1 means "nothing found" for pacman and the AUR helpers.
    return switch (id) {
      'pacman' => parsePacmanSearch(await run(['-Ss', '--', _regexEscape(query)], ok: {0, 1}), 'pacman'),
      'aur' => parsePacmanSearch(await run(['-Ssa', '--', query], ok: {0, 1}), 'aur'),
      'flatpak' => parseFlatpakSearch(await run(['search', '--columns=application,version,remotes,name,description', query])),
      'apt' => parseAptSearch(await readBoundedText(
        [session.which('apt-cache') ?? 'apt-cache', 'search', '--', query],
        maxBytes: 2 * 1024 * 1024,
        timeout: const Duration(seconds: 30),
        environment: {...session.environment, 'LC_ALL': 'C'},
      )),
      'dnf' => parseDnfSearch(await run(['search', '-q', '--', query], ok: {0, 1})),
      'zypper' => parseZypperSearch(await run(['-n', '--no-refresh', 'search', '--', query], ok: {0, 104})),
      'snap' => parseSnapFind(await run(['find', '--', query])),
      _ => <Found>[],
    };
  }

  /// The terminal line for an install: the package (and Flatpak's remote)
  /// as positional arguments.
  List<String>? installCommand(String manager, Found found, List<String> terminal) {
    final package = found['package'] as String;
    if (!validPackage(package)) return null;
    final helper = installed()[manager];
    if (helper == null) return null;
    final line = switch (manager) {
      'pacman' => 'sudo pacman -S -- "\$1"',
      'aur' => '${p.basename(helper)} -S -- "\$1"',
      'flatpak' => 'flatpak install -- "\$2" "\$1"',
      'snap' => 'sudo snap install -- "\$1"',
      'apt' => 'sudo apt install -- "\$1"',
      'dnf' => 'sudo dnf install -- "\$1"',
      'zypper' => 'sudo zypper install -- "\$1"',
      _ => null,
    };
    if (line == null) return null;
    final remote = (found['remote'] as String? ?? 'flathub').split(',').first;
    if (manager == 'flatpak' && !validPackage(remote)) return null;
    return [
      ...terminal,
      'sh',
      '-c',
      "$line; echo; read -r -p 'Press Enter to close. ' _",
      'install',
      package,
      if (manager == 'flatpak') remote,
    ];
  }

  /// The system package that owns [path], and its manager, or null.
  Future<(String, String)?> ownerOf(String path) async {
    if (!p.isAbsolute(path)) return null;
    Future<String?> first(List<String> command) async {
      final out = await readBoundedText(
        command,
        maxBytes: 64 * 1024,
        timeout: const Duration(seconds: 5),
        environment: {...session.environment, 'LC_ALL': 'C'},
      );
      final line = (out ?? '').trim().split('\n').first.trim();
      return line.isEmpty ? null : line;
    }

    final there = installed();
    if (there['pacman'] != null) {
      final name = await first([there['pacman']!, '-Qqo', '--', path]);
      if (name != null && validPackage(name)) return ('pacman', name);
    }
    final dpkg = session.which('dpkg');
    if (dpkg != null) {
      final line = await first([dpkg, '-S', '--', path]);
      final name = line?.split(':').first.trim();
      if (name != null && validPackage(name)) return ('apt', name);
    }
    final rpm = session.which('rpm');
    if (rpm != null) {
      final name = await first([rpm, '-qf', '--queryformat', '%{NAME}\n', '--', path]);
      if (name != null && validPackage(name) && !name.contains(' ')) {
        return (there['zypper'] != null ? 'zypper' : 'dnf', name);
      }
    }
    return null;
  }

  /// The terminal line that removes a system package.
  List<String>? removeCommand(String manager, String package, List<String> terminal) {
    if (!validPackage(package)) return null;
    final line = switch (manager) {
      'pacman' => 'sudo pacman -Rns -- "\$1"',
      'apt' => 'sudo apt remove -- "\$1"',
      'dnf' => 'sudo dnf remove -- "\$1"',
      'zypper' => 'sudo zypper remove -- "\$1"',
      'snap' => 'sudo snap remove -- "\$1"',
      _ => null,
    };
    if (line == null) return null;
    return [...terminal, 'sh', '-c', "$line; echo; read -r -p 'Press Enter to close. ' _", 'uninstall', package];
  }

  /// One terminal line that removes several system packages of [manager].
  List<String>? removeManyCommand(String manager, List<String> packages, List<String> terminal) {
    if (packages.isEmpty || !packages.every(validPackage)) return null;
    final line = switch (manager) {
      'pacman' => 'sudo pacman -Rns -- "\$@"',
      'apt' => 'sudo apt remove -- "\$@"',
      'dnf' => 'sudo dnf remove -- "\$@"',
      'zypper' => 'sudo zypper remove -- "\$@"',
      'snap' => 'sudo snap remove -- "\$@"',
      _ => null,
    };
    if (line == null) return null;
    return [...terminal, 'sh', '-c', "$line; echo; read -r -p 'Press Enter to close. ' _", 'uninstall', ...packages];
  }

  /// The installed packages that need [package] (pacman's "Required By"):
  /// pacman refuses to remove it while they stay. Empty for other managers,
  /// which offer to remove the dependents along with it.
  Future<List<String>> neededBy(String manager, String package) async {
    final pacman = installed()['pacman'];
    if (manager != 'pacman' || pacman == null || !validPackage(package)) return const [];
    final out = await readBoundedText(
      [pacman, '-Qi', '--', package],
      maxBytes: 1024 * 1024,
      timeout: const Duration(seconds: 5),
      environment: {...session.environment, 'LC_ALL': 'C'},
    );
    return parseRequiredBy(out);
  }
}

/// The "Required By" field of `pacman -Qi` (LC_ALL=C), wrapped lines too.
List<String> parseRequiredBy(String? text) {
  final out = <String>[];
  var inField = false;
  for (final line in (text ?? '').split('\n')) {
    if (line.startsWith('Required By')) {
      inField = true;
      out.addAll(line.substring(line.indexOf(':') + 1).trim().split(RegExp(r'\s+')));
    } else if (inField && line.startsWith(' ') && !line.contains(' : ')) {
      out.addAll(line.trim().split(RegExp(r'\s+')));
    } else {
      inField = false;
    }
  }
  return [
    for (final name in out)
      if (name.isNotEmpty && name != 'None' && validPackage(name)) name,
  ];
}

// --- search output --------------------------------------------------------------

final _pacmanHead = RegExp(r'^([A-Za-z0-9_.-]+)/(\S+) (\S+)(.*)$');

/// `pacman -Ss` / `yay -Ssa`: "repo/name version [groups] [installed]",
/// then the description indented.
List<Found> parsePacmanSearch(String? text, String manager) {
  final out = <Found>[];
  for (final line in (text ?? '').split('\n')) {
    final head = _pacmanHead.firstMatch(line);
    if (head != null && !line.startsWith(' ')) {
      if (!validPackage(head[2]!)) continue;
      out.add({
        'manager': manager,
        'repo': head[1],
        'package': head[2],
        'version': head[3],
        'installed': head[4]!.contains('[installed') || head[4]!.contains('[Installed'),
        'description': '',
        if (manager == 'aur') 'aur': true,
      });
    } else if (line.startsWith('    ') && out.isNotEmpty && (out.last['description'] as String).isEmpty) {
      out.last['description'] = line.trim();
    }
  }
  return out;
}

/// `flatpak search --columns=application,version,remotes,name,description`.
List<Found> parseFlatpakSearch(String? text) => [
  for (final line in (text ?? '').split('\n'))
    if (line.split('\t') case [final id, final version, final remotes, final name, final description, ...]
        when flatpakIdRe.hasMatch(id.trim()))
      {
        'manager': 'flatpak',
        'package': id.trim(),
        'version': version.trim(),
        'remote': remotes.trim(),
        'name': name.trim(),
        'description': description.trim(),
        'installed': false,
      },
];

/// `apt-cache search`: "name - description".
List<Found> parseAptSearch(String? text) => [
  for (final line in (text ?? '').split('\n'))
    if (RegExp(r'^(\S+) - (.*)$').firstMatch(line) case final m? when validPackage(m[1]!))
      {'manager': 'apt', 'package': m[1], 'version': '', 'description': m[2]!.trim(), 'installed': false},
];

/// `dnf search -q`: "name.arch : summary" (dnf4) or " name.arch\tsummary" (dnf5).
List<Found> parseDnfSearch(String? text) => [
  for (final line in (text ?? '').split('\n'))
    if (RegExp(r'^\s*([A-Za-z0-9@_+.-]+)\.(?:x86_64|noarch|i686|aarch64)\s*(?::\s*|\t)(.*)$').firstMatch(line)
        case final m? when validPackage(m[1]!))
      {'manager': 'dnf', 'package': m[1], 'version': '', 'description': m[2]!.trim(), 'installed': false},
];

/// `zypper search`: "S | Name | Summary | Type" rows.
List<Found> parseZypperSearch(String? text) => [
  for (final line in (text ?? '').split('\n'))
    if (line.split('|').map((c) => c.trim()).toList() case [final s, final name, final summary, final type, ...]
        when type == 'package' && validPackage(name))
      {'manager': 'zypper', 'package': name, 'version': '', 'description': summary, 'installed': s.startsWith('i')},
];

/// `snap find`: "Name  Version  Publisher  Notes  Summary".
List<Found> parseSnapFind(String? text) {
  final lines = (text ?? '').split('\n');
  return [
    for (final line in lines.skip(1))
      if (RegExp(r'^(\S+)\s+(\S+)\s+\S+\s+\S+\s+(.*)$').firstMatch(line) case final m? when validPackage(m[1]!))
        {'manager': 'snap', 'package': m[1], 'version': m[2], 'description': m[3]!.trim(), 'installed': false},
  ];
}

// --- the trash ------------------------------------------------------------------

/// Move [path] to the user's trash (freedesktop trash spec: files/ and an
/// `info/<name>.trashinfo`), as Gio's trash does for files in the home.
String? moveToTrash(String path, Session session) {
  final env = session.environment;
  final data = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : p.join(session.home, '.local/share');
  final trash = p.join(data, 'Trash');
  final files = Directory(p.join(trash, 'files'))..createSync(recursive: true);
  final info = Directory(p.join(trash, 'info'))..createSync(recursive: true);
  final base = p.basename(path);
  var name = base;
  for (var n = 2; File(p.join(info.path, '$name.trashinfo')).existsSync() ||
      FileSystemEntity.typeSync(p.join(files.path, name), followLinks: false) != FileSystemEntityType.notFound; n++) {
    name = '$base.$n';
  }
  final now = DateTime.now();
  String two(int v) => '$v'.padLeft(2, '0');
  final date = '${now.year}-${two(now.month)}-${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  final infoFile = File(p.join(info.path, '$name.trashinfo'));
  infoFile.writeAsStringSync('[Trash Info]\nPath=${Uri(path: p.absolute(path)).toString()}\nDeletionDate=$date\n');
  try {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      Link(path).renameSync(p.join(files.path, name));
    } else {
      File(path).renameSync(p.join(files.path, name));
    }
    return p.join(files.path, name);
  } on FileSystemException {
    infoFile.deleteSync();
    return null;
  }
}
