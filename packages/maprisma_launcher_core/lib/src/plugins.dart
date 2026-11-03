/// Omarchy shell plugins as a second list (reference/omarchy-plugin:
/// launcher_core parse_plugins, plugin_can_open, plugin_removal_note;
/// updates.plugin_behind, run_plugin_update). Everything goes through
/// Omarchy's own commands (omarchy-shell, omarchy-plugin-enable/-disable/
/// -remove, omarchy plugin update); ids are checked against what the shell lists.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'posix.dart';

/// Ours (the bar button that starts Maprisma Launcher) and helpers the shell
/// summons itself with a payload: nothing to open from a list.
const internalPlugins = {'ubruckhaus.maprisma-launcher', 'omarchy.image-picker', 'omarchy.osd'};
const loaderKinds = ['panel', 'overlay', 'menu'];
const barSections = ['left', 'center', 'right'];
final pluginIdRe = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');
final _panelRoot = RegExp(r'^(?:[A-Za-z]+\.)?Panel\s*\{', multiLine: true);
const maxManifestBytes = 256 * 1024, maxQmlBytes = 1024 * 1024;

final class ShellPlugins {
  ShellPlugins(this.session);
  final Session session;

  String get userDir => p.join(session.home, '.config/omarchy/plugins');
  String get omarchyRoot => session.environment['OMARCHY_PATH']?.isNotEmpty == true
      ? session.environment['OMARCHY_PATH']!
      : '/usr/share/omarchy';
  List<String> get roots => [userDir, p.join(omarchyRoot, 'shell/plugins')];

  Map<String, String> get _gitEnv => {
    ...session.environment,
    // Never ask for a password or a host key: a check runs unattended.
    'GIT_TERMINAL_PROMPT': '0', 'GIT_ASKPASS': '/bin/true', 'SSH_ASKPASS': '/bin/true',
    'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o ConnectTimeout=10', 'LC_ALL': 'C',
  };

  /// plugin_manifests: id → (directory, manifest), the user's first.
  Map<String, (String, Map)> manifests() {
    final found = <String, (String, Map)>{};
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      final paths = <String>[];
      try {
        for (final e in dir.listSync()) {
          paths.add(p.join(e.path, 'manifest.json'));
          if (FileSystemEntity.isDirectorySync(e.path)) {
            for (final sub in Directory(e.path).listSync()) {
              paths.add(p.join(sub.path, 'manifest.json'));
            }
          }
        }
      } on FileSystemException {
        continue;
      }
      paths.sort();
      for (final path in paths) {
        final bytes = Posix.instance.readRegular(path, maxManifestBytes);
        if (bytes == null) continue;
        Object? manifest;
        try {
          manifest = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        } on FormatException {
          continue;
        }
        final id = manifest is Map ? manifest['id'] : null;
        if (id is String && !found.containsKey(id)) found[id] = (p.dirname(path), manifest as Map);
      }
    }
    return found;
  }

  /// plugin_can_open: a panel, overlay or menu, or a bar widget that is a
  /// panel itself (what `omarchy-shell shell summon` can open).
  bool canOpen(String directory, Map manifest) {
    final kinds = (manifest['kinds'] as List? ?? const []).whereType<String>();
    if (kinds.any(loaderKinds.contains)) return true;
    if (!kinds.contains('bar-widget')) return false;
    final entry = (manifest['entryPoints'] as Map?)?['barWidget'];
    if (entry is! String) return false;
    try {
      final base = Directory(directory).resolveSymbolicLinksSync();
      final path = File(p.join(directory, entry)).resolveSymbolicLinksSync();
      if (!p.isWithin(base, path)) return false;
      final bytes = Posix.instance.readRegular(path, maxQmlBytes);
      if (bytes == null) return false;
      final text = utf8.decode(bytes, allowMalformed: true);
      return _panelRoot.hasMatch(text) || (text.contains('function open') && text.contains('opened'));
    } on FileSystemException {
      return false;
    }
  }

  bool removable(String id) {
    final target = p.join(userDir, id);
    return pluginIdRe.hasMatch(id) &&
        !id.contains('..') &&
        FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound &&
        session.which('omarchy-plugin-remove') != null;
  }

  /// parse_plugins: the shell's plugins that have something to open, as
  /// entries: enabled panels and overlays, and bar widgets with a panel, in
  /// the bar or not (out of it they can be put back).
  Future<List<Map<String, dynamic>>> list() async {
    final shell = session.which('omarchy-shell');
    if (shell == null) return [];
    final out = await readBoundedText([shell, 'shell', 'listPlugins'],
        maxBytes: 512 * 1024, timeout: const Duration(seconds: 2), environment: session.environment);
    Object? listed;
    try {
      listed = out == null ? null : jsonDecode(out);
    } on FormatException {
      listed = null;
    }
    if (listed is! List) return [];
    final all = manifests();
    final plugins = <Map<String, dynamic>>[];
    for (final item in listed.whereType<Map>()) {
      final id = '${item['id'] ?? ''}';
      if (!pluginIdRe.hasMatch(id) || internalPlugins.contains(id)) continue;
      final found = all[id];
      if (found == null) continue; // Parts built into the bar: nothing to open.
      final (directory, manifest) = found;
      final kinds = (manifest['kinds'] as List? ?? const []).whereType<String>().toList();
      final barWidget = kinds.contains('bar-widget');
      final enabled = item['enabled'] == true;
      final can = canOpen(directory, manifest);
      if (!can || !(enabled || barWidget)) continue;
      final bar = manifest['barWidget'] is Map ? manifest['barWidget'] as Map : const {};
      final description = manifest['description'];
      final category = '${bar['category'] ?? manifest['category'] ?? ''}';
      plugins.add({
        'name': '${item['name'] ?? manifest['name'] ?? id}',
        'plugin_id': id,
        'key': 'plugin:$id',
        'description': description is String ? description.trim() : '',
        'removable': removable(id),
        'bar_widget': barWidget,
        'bar_section': bar['defaultSection'] is String ? bar['defaultSection'] : null,
        'plugin_dir': directory,
        'category': category.length > 40 ? category.substring(0, 40) : category,
        'in_bar': barWidget && enabled,
        'openable': can && (enabled || kinds.any(loaderKinds.contains)),
        'first_party': item['firstParty'] == true,
        'version': manifest['version'] is String ? manifest['version'] : '',
      });
    }
    plugins.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    return plugins;
  }

  /// open_plugin: the shell opens (summons) it; true when it says ok.
  Future<bool> open(String id) async {
    final shell = session.which('omarchy-shell');
    if (shell == null || !pluginIdRe.hasMatch(id)) return false;
    final out = await readBoundedText([shell, 'shell', 'summon', id, '{}'],
        maxBytes: 4096, timeout: const Duration(seconds: 3), environment: session.environment);
    return out?.trim() == 'ok';
  }

  /// set_in_bar: Omarchy's own enable/disable; a section when given.
  Future<bool> setInBar(String id, bool placed, String? section) async {
    if (!pluginIdRe.hasMatch(id) || (section != null && !barSections.contains(section))) return false;
    final command = session.which(placed ? 'omarchy-plugin-enable' : 'omarchy-plugin-disable');
    if (command == null) return false;
    final out = await readBoundedText([command, id, if (placed && section != null) section],
        maxBytes: 64 * 1024, timeout: const Duration(seconds: 20), environment: session.environment);
    return out != null;
  }

  Future<String?> _git(String dir, List<String> args, {Duration timeout = const Duration(seconds: 5)}) =>
      readBoundedText([session.which('git') ?? 'git', '-C', dir, ...args],
          maxBytes: 256 * 1024, timeout: timeout, environment: _gitEnv);

  /// plugin_removal_note: what `omarchy plugin remove` does with the folder,
  /// and whether work would be lost (it deletes git checkouts outright).
  Future<Map<String, dynamic>> removalNote(String id) async {
    final target = p.join(userDir, id);
    if (FileSystemEntity.isLinkSync(target)) return {'note': 'link', 'loses_work': false};
    if (!Directory(p.join(target, '.git')).existsSync()) return {'note': 'backup', 'loses_work': false};
    final changed = await _git(target, ['status', '--porcelain']);
    final ahead = await _git(target, ['rev-list', '--count', '@{u}..HEAD']);
    final changedCount = changed?.trim().split('\n').where((l) => l.isNotEmpty).length;
    final aheadCount = ahead == null ? null : int.tryParse(ahead.trim()) ?? 0;
    final loses = changed == null || changedCount! > 0 || ahead == null || aheadCount! > 0;
    return {
      'note': loses ? 'loses' : 'deleted',
      'loses_work': loses,
      'changed': changedCount,
      'unchecked': changed == null,
      'ahead': aheadCount,
      'no_upstream': ahead == null,
    };
  }

  Future<bool> remove(String id) async {
    final command = session.which('omarchy-plugin-remove');
    if (command == null || !removable(id)) return false;
    final out = await readBoundedText([command, id, '--yes'],
        maxBytes: 64 * 1024, timeout: const Duration(seconds: 60), environment: session.environment);
    return out != null;
  }

  /// plugin_behind: commits the checkout is behind origin's default branch.
  Future<int?> behind(String id, {bool fetch = true}) async {
    final dir = p.join(userDir, id);
    if (!pluginIdRe.hasMatch(id) || !Directory(p.join(dir, '.git')).existsSync()) return null;
    if (fetch) await _git(dir, ['fetch', '--quiet', '--no-tags', 'origin', 'HEAD'], timeout: const Duration(seconds: 30));
    final count = await _git(dir, ['rev-list', '--count', 'HEAD..FETCH_HEAD']);
    return count == null ? null : int.tryParse(count.trim());
  }

  /// run_plugin_update: `omarchy plugin update <id> --yes` (fast-forward
  /// only, validated, rolled back on failure). (ok, message).
  Future<(bool, String)> update(String id) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id) || id.contains('..')) {
      return (false, 'invalid plugin id');
    }
    final omarchy = session.which('omarchy');
    if (omarchy == null) return (false, 'no omarchy command');
    final (code, output) = await runBounded([omarchy, 'plugin', 'update', id, '--yes'],
        maxBytes: 64 * 1024, timeout: const Duration(seconds: 180), environment: _gitEnv);
    if (code == 0) return (true, '');
    // The command's last line says why (local changes, validation …).
    final lines = [for (final l in output.split('\n')) if (l.trim().isNotEmpty) l.trim()];
    var message = lines.isNotEmpty ? lines.last : (code == null ? 'timed out or too much output' : 'exit $code');
    if (message.startsWith('omarchy-plugin-update: ')) message = message.substring('omarchy-plugin-update: '.length);
    return (false, message.length > 300 ? message.substring(0, 300) : message);
  }
}
