/// Standalone AppImages: launcher_core.scan_standalone_appimages and the
/// version-aware name helpers.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'posix.dart';
import 'shlex.dart';

const maxAppImageIconBytes = 2 * 1024 * 1024;

const _noise = {
  'linux', 'gnu', 'appimage', 'x86', 'x64', 'x86-64', 'amd64', 'i386', 'i686',
  'aarch64', 'arm64', 'armhf', 'armv7l', 'universal', 'portable',
};

final _versionWord = RegExp(
  r'^(?:v?\d+(?:\.\d+)*(?:[.+~]?[a-z][\w.+~]*)?|v?\d+(?:\.\d+)+[\w.+~]*)$',
  caseSensitive: false,
);
final _release = RegExp(r'^v?(\d+(?:\.\d+)*)(.*)$', caseSensitive: false, dotAll: true);
final _prerelease = RegExp(
  r'^[.~-]?(alpha|beta|preview|pre|rc|dev|nightly|a|b)\.?(\d*)$',
  caseSensitive: false,
);
final _cpu = RegExp(
  r'(?<![^-_ .])(?:x86[-_]64|aarch64|arm64|amd64|armv7l|i[36]86)(?=$|[-_ .])',
  caseSensitive: false,
);
const _stages = {
  'dev': 0, 'nightly': 0, 'alpha': 1, 'a': 1, 'beta': 2, 'b': 2,
  'pre': 3, 'preview': 3, 'rc': 4,
};

bool isVersionWord(String word) {
  if (!_versionWord.hasMatch(word)) return false;
  final release = _release.firstMatch(word)!;
  final tail = release[2]!;
  return tail.isEmpty ||
      release[1]!.contains('.') ||
      _prerelease.hasMatch(tail) ||
      '.+~'.contains(tail[0]) ||
      'vV'.contains(word[0]);
}

(List<String>, List<String>) appImageWords(String stem) {
  final words = stem
      .replaceAll(_cpu, '')
      .split(RegExp(r'[-_ ]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  var cut = words.length;
  for (var i = 1; i < words.length; i++) {
    if (isVersionWord(words[i])) {
      cut = i;
      break;
    }
  }
  final name = [
    for (var i = 0; i < cut; i++)
      if (!(i > 0 && _noise.contains(words[i].toLowerCase()))) words[i],
  ];
  return (name, words.sublist(cut));
}

String appImageBaseName(String stem) {
  final name = appImageWords(stem).$1.join(' ');
  return name.isEmpty ? stem : name;
}

String nameKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'[-_ ]'), '');

/// Comparable version of an AppImage file name (larger is newer).
(List<int>, int, List<int>) versionKey(String stem) {
  final release = <int>[];
  List<int>? pre;
  final words = <String>[];
  for (final word in appImageWords(stem).$2) {
    final plus = word.indexOf('+');
    words.add(plus < 0 ? word : word.substring(0, plus));
    if (plus >= 0) break;
  }
  for (final word in words) {
    final tag = _prerelease.firstMatch(word);
    if (tag != null) {
      pre ??= [_stages[tag[1]!.toLowerCase()]!, int.tryParse(tag[2]!) ?? 0];
      continue;
    }
    final match = _release.firstMatch(word);
    if (match == null) continue;
    release.addAll(match[1]!.split('.').map((n) => int.tryParse(n) ?? 0x7fffffffffffffff));
    final rest = match[2]!;
    final tail = rest.isEmpty ? null : _prerelease.firstMatch(rest);
    if (tail != null) {
      pre ??= [_stages[tail[1]!.toLowerCase()]!, int.tryParse(tail[2]!) ?? 0];
    }
  }
  while (release.isNotEmpty && release.last == 0) {
    release.removeLast();
  }
  return (release, pre == null ? 1 : 0, pre ?? const []);
}

int _compareLists(List<int> a, List<int> b) {
  for (var i = 0; i < min(a.length, b.length); i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

int compareVersionKeys(
  (List<int>, int, List<int>) a,
  (List<int>, int, List<int>) b,
) {
  final r = _compareLists(a.$1, b.$1);
  if (r != 0) return r;
  if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
  return _compareLists(a.$3, b.$3);
}

String _stem(String path) {
  final name = p.basename(path);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// One app's versions together, the newest first (stable sorts, as Python).
List<String> sortedNewestFirst(List<String> paths) {
  final list = [...paths]..sort((a, b) => p.basename(a).compareTo(p.basename(b)));
  _stableSort(list, (a, b) => compareVersionKeys(versionKey(_stem(b)), versionKey(_stem(a))));
  _stableSort(
    list,
    (a, b) => nameKey(appImageBaseName(_stem(a))).compareTo(nameKey(appImageBaseName(_stem(b)))),
  );
  return list;
}

void _stableSort<T>(List<T> list, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final r = compare(a.$2, b.$2);
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

List<String> appImageDirectories(Session session) => [
  for (final dir in ['AppImages', 'Applications', '.local/bin', 'bin'])
    if (FileSystemEntity.isDirectorySync(p.join(session.home, dir)))
      p.join(session.home, dir),
];

/// Extract the AppImage's icon into one cache slot per AppImage (bounded
/// pipe; the archive never names a destination).
Future<String> cacheAppImageIcon(
  String path,
  String rawIcon,
  String cacheDir,
  String sevenZip,
) async {
  final iconName = p.basename(rawIcon);
  if (iconName.isEmpty || iconName == '.' || iconName == '..') return '';
  String resolved;
  try {
    resolved = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    resolved = p.absolute(path);
  }
  final key = sha256.convert(utf8.encode(resolved));
  final target = p.join(cacheDir, '$key.icon');
  final members = iconName.endsWith('.png') || iconName.endsWith('.svg')
      ? [iconName]
      : ['$iconName.png', '$iconName.svg'];
  for (final member in members) {
    final data = await readBoundedBytes(
      [sevenZip, 'e', '-so', '-spd', path, member],
      maxBytes: maxAppImageIconBytes,
      timeout: const Duration(seconds: 2),
    );
    if (data == null || data.isEmpty) continue;
    Directory(cacheDir).createSync(recursive: true);
    final temporary = File(p.join(cacheDir, '.tmp-${DateTime.now().microsecondsSinceEpoch}-$pid'));
    try {
      temporary.writeAsBytesSync(data, flush: true);
      temporary.renameSync(target);
      return target;
    } on FileSystemException {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
  return '';
}

Future<List<Map<String, dynamic>>> scanStandaloneAppImages(
  Session session,
  Set<String> seenNames, {
  Set<String> started = const {},
  String cacheName = 'maprisma-launcher',
}) async {
  final apps = <Map<String, dynamic>>[];
  final iconCache = p.join(session.home, '.cache/$cacheName/icons');
  final sevenZip = session.which('7z');
  final taken = {for (final s in started) nameKey(appImageBaseName(_stem(s)))};
  final found = <String>[];
  final pattern = RegExp(r'^.*\.appimage$', caseSensitive: false);
  for (final dir in appImageDirectories(session)) {
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        // pathlib's "*.[aA]…" needs at least the dot: ".AppImage" alone counts too.
        if (pattern.hasMatch(name)) found.add(e.path);
      }
    } on FileSystemException {
      continue;
    }
  }
  for (final path in sortedNewestFirst(found)) {
    if (!FileSystemEntity.isFileSync(path) || !Posix.instance.executable(path)) {
      continue;
    }
    final identity = nameKey(appImageBaseName(_stem(path)));
    if (started.contains(path) || taken.contains(identity)) continue;
    taken.add(identity);
    var appName = '', appDesc = '', iconPath = '', startupClass = '', rawIcon = '';
    if (sevenZip != null) {
      final text = await readBoundedText([sevenZip, 'e', '-so', path, '*.desktop']);
      if (text != null && text.contains('[Desktop Entry]')) {
        for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
          String value() => line.substring(line.indexOf('=') + 1).trim();
          if (line.startsWith('Name=') && appName.isEmpty) {
            appName = value();
          } else if (line.startsWith('Comment=') && appDesc.isEmpty) {
            appDesc = value();
          } else if (line.startsWith('StartupWMClass=')) {
            startupClass = value();
          } else if (line.startsWith('Icon=') && rawIcon.isEmpty) {
            rawIcon = value();
          }
        }
        if (rawIcon.isNotEmpty) {
          iconPath = await cacheAppImageIcon(path, rawIcon, iconCache, sevenZip);
        }
      }
    }
    if (appName.isEmpty) appName = appImageBaseName(_stem(path));
    final key = appName.trim().toLowerCase();
    if (seenNames.contains(key)) continue;
    final normalized = nameKey(key);
    if (seenNames.any((s) => nameKey(s) == normalized)) continue;
    seenNames.add(key);
    apps.add({
      'name': appName,
      'exec': shlexJoin([path]),
      'argv': [path],
      'icon': iconPath.isEmpty ? 'application-x-executable' : iconPath,
      'desktop_path': '',
      'actions': <Map<String, String>>[],
      'description': appDesc,
      'desktop_id': _stem(path),
      'startup_class': startupClass.isEmpty ? _stem(path) : startupClass,
    });
  }
  return apps;
}
