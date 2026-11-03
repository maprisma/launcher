/// Icon names → files, as the freedesktop icon theme spec finds them: the
/// desktop's theme, the themes it inherits, hicolor, then pixmaps. Each
/// theme folder is listed once and kept (an index per theme chain).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';
import 'desktops.dart';
import 'posix.dart';

final class IconTheme {
  IconTheme(this.session, String? theme) {
    _bases = [
      p.join(session.home, '.icons'),
      for (final dir in iconDataDirs(session)) p.join(dir, 'icons'),
    ];
    final chain = <String>[];
    void add(String name, int depth) {
      if (depth > 8 || chain.contains(name) || name == 'hicolor') return;
      final index = _indexFile(name);
      if (index == null) return;
      chain.add(name);
      for (final parent in (_value(index, 'Inherits') ?? '').split(',')) {
        if (parent.trim().isNotEmpty) add(parent.trim(), depth + 1);
      }
    }

    if (theme != null && theme.isNotEmpty) add(theme, 0);
    chain.add('hicolor');
    themes = chain;
  }

  final Session session;
  late final List<String> _bases;
  late final List<String> themes;
  final _index = <String, Map<String, (int, String)>>{};
  final _cache = <String, String?>{};

  String? _indexFile(String theme) {
    for (final base in _bases) {
      final bytes = Posix.instance.readRegular(
        p.join(base, theme, 'index.theme'),
        256 * 1024,
      );
      if (bytes != null) return utf8.decode(bytes, allowMalformed: true);
    }
    return null;
  }

  static String? _value(String text, String key) {
    final m = RegExp('^$key\\s*=\\s*(.*)\$', multiLine: true).firstMatch(text);
    return m?[1]?.trim();
  }

  /// name → (rank, path) for one theme: scalable SVGs rank highest, then
  /// the largest bitmap; symbolic and XPM files are left out.
  Map<String, (int, String)> _themeIndex(String theme) => _index.putIfAbsent(theme, () {
    final found = <String, (int, String)>{};
    for (final base in _bases.reversed) {
      final root = Directory(p.join(base, theme));
      if (!root.existsSync()) continue;
      List<FileSystemEntity> files;
      try {
        files = root.listSync(recursive: true, followLinks: true);
      } on FileSystemException {
        continue;
      }
      for (final f in files) {
        final file = f.path;
        final ext = p.extension(file);
        if (ext != '.svg' && ext != '.png') continue;
        final name = p.basenameWithoutExtension(file);
        if (name.endsWith('-symbolic')) continue;
        final rel = p.split(p.relative(file, from: root.path));
        var rank = 0;
        for (final part in rel) {
          if (part.startsWith('scalable') || part == 'scalable') rank = 10000;
          final size = RegExp(r'^(\d+)(?:x\d+)?(?:@(\d+)x?)?$').firstMatch(part);
          if (size != null && rank < 10000) {
            rank = int.parse(size[1]!) * (int.tryParse(size[2] ?? '') ?? 1);
          }
        }
        if (ext == '.svg' && rank < 10000) rank += 5000;
        final old = found[name];
        if (old == null || rank > old.$1) found[name] = (rank, file);
      }
    }
    return found;
  });

  /// The file for an Icon= value: an absolute path as it is, else a name.
  String? lookup(String icon) {
    if (icon.isEmpty) return null;
    return _cache.putIfAbsent(icon, () {
      if (icon.startsWith('/')) {
        return FileSystemEntity.isFileSync(icon) ? icon : null;
      }
      if (icon.contains('/') || icon.startsWith('.')) return null;
      var name = icon;
      for (final ext in ['.png', '.svg', '.xpm']) {
        if (name.endsWith(ext)) name = name.substring(0, name.length - ext.length);
      }
      for (final theme in themes) {
        final hit = _themeIndex(theme)[name];
        if (hit != null) return hit.$2;
      }
      for (final dir in iconDataDirs(session)) {
        for (final ext in ['svg', 'png']) {
          final file = p.join(dir, 'pixmaps', '$name.$ext');
          if (FileSystemEntity.isFileSync(file)) return file;
        }
      }
      return null;
    });
  }

  static Future<IconTheme> forDesktop(Desktop desktop) async =>
      IconTheme(desktop.session, await desktop.iconTheme());
}

/// launcher_core.icon_data_dirs: XDG_DATA_HOME first, then XDG_DATA_DIRS.
List<String> iconDataDirs(Session session) {
  final env = session.environment;
  final home = env['XDG_DATA_HOME']?.isNotEmpty == true
      ? env['XDG_DATA_HOME']!
      : p.join(session.home, '.local/share');
  final system = env['XDG_DATA_DIRS']?.isNotEmpty == true
      ? env['XDG_DATA_DIRS']!
      : '/usr/local/share:/usr/share';
  return [home, ...system.split(':').where((d) => d.isNotEmpty)];
}
