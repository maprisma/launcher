/// Icons chosen by hand (reference icons.py): icons.json maps a desktop id to
/// a theme icon name or to a file saved in the app's own icon folder.
/// Online candidates come from three open collections on cdn.jsdelivr.net
/// (Dashboard Icons, selfh.st, Simple Icons): their name lists are fetched at
/// most once a week and searched by name, alias and word; icons are fetched
/// with curl (https only, no redirects, one deadline, a size cap) and only
/// kept when they look like an SVG or a PNG.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'config.dart';
import 'desktop_entries.dart';
import 'posix.dart';

const host = 'cdn.jsdelivr.net';
const maxIconBytes = 1024 * 1024, maxIndexBytes = 4 * 1024 * 1024;
const iconTimeout = 8, indexTimeout = 20;
const indexMaxAge = Duration(days: 7);
const maxOnlineResults = 24, maxThemeResults = 48, maxOverrides = 2000;

const indexes = {
  'dashboard': 'https://$host/gh/homarr-labs/dashboard-icons/metadata.json',
  'selfhst': 'https://$host/gh/selfhst/icons/index.json',
  'simple': 'https://$host/npm/simple-icons@latest/data/simple-icons.json',
};
const collectionNames = {'dashboard': 'Dashboard Icons', 'selfhst': 'selfh.st', 'simple': 'Simple Icons'};
const aliases = {
  'codex': ['codex', 'openai'], 'cursor-agent': ['cursor'], 'cursor': ['cursor'],
  'copilot': ['github-copilot', 'copilot', 'github'], 'github copilot cli': ['github-copilot'],
  'claude': ['claude', 'anthropic'], 'claude code': ['claude', 'anthropic'],
  'gemini': ['google-gemini', 'gemini'], 'gemini cli': ['google-gemini'],
  'opencode': ['opencode'], 'grok': ['grok', 'x'], 'crush': ['charm', 'crush'],
  'lm studio': ['lm-studio', 'lmstudio'], 'pi': ['pi'], 'oh my pi': ['pi'],
  'vs code': ['visual-studio-code', 'vscode'], 'code': ['visual-studio-code', 'vscode'],
};
final _indexSlug = RegExp(r'^[a-z0-9][a-z0-9._-]{0,79}$');
final _name = RegExp(r'^[A-Za-z0-9._+-]{1,128}$');
final _url = RegExp(r'^https://cdn\.jsdelivr\.net/[A-Za-z0-9@._/-]{1,200}\.(?:svg|png|json)$');

/// One online icon: (collection, slug, url, kind: svg | png | mono).
typedef Candidate = (String, String, String, String);

String fold(Object? text) => '${text ?? ''}'
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .join(' ');

/// icons.index_entries: one collection's name list → entries with their names.
List<(Candidate, List<String>)> indexEntries(String key, Object? data) {
  final out = <(Candidate, List<String>)>[];
  if (key == 'dashboard' && data is Map) {
    for (final e in data.entries.take(20000)) {
      final slug = e.key, meta = e.value;
      if (slug is! String || !_indexSlug.hasMatch(slug) || meta is! Map) continue;
      final kind = meta['base'] == 'png' ? 'png' : 'svg';
      final names = [slug, if (meta['aliases'] is List) ...(meta['aliases'] as List).take(20).whereType<String>()];
      out.add((('dashboard', slug, 'https://$host/gh/homarr-labs/dashboard-icons/$kind/$slug.$kind', kind), names));
    }
  } else if (key == 'selfhst' && data is List) {
    for (final item in data.take(20000)) {
      if (item is! Map) continue;
      final slug = item['Reference'], name = item['Name'];
      if (slug is! String || !_indexSlug.hasMatch(slug)) continue;
      final kind = item['SVG'] == 'Yes' ? 'svg' : item['PNG'] == 'Yes' ? 'png' : null;
      if (kind == null) continue;
      final tags = item['Tags'] is String ? item['Tags'] as String : '';
      final names = [
        slug,
        if (name is String) name,
        ...tags.split(',').take(20).where((t) => t.trim().isNotEmpty),
      ];
      out.add((('selfhst', slug, 'https://$host/gh/selfhst/icons/$kind/$slug.$kind', kind), names));
    }
  } else if (key == 'simple' && data is List) {
    for (final item in data.take(20000)) {
      if (item is! Map) continue;
      final slug = item['slug'], title = item['title'];
      if (slug is! String || !_indexSlug.hasMatch(slug) || slug.contains('.')) continue;
      final aka = item['aliases'] is Map ? (item['aliases'] as Map)['aka'] : null;
      final names = [slug, if (title is String) title, if (aka is List) ...aka.take(20).whereType<String>()];
      out.add((('simple', slug, 'https://$host/npm/simple-icons@latest/icons/$slug.svg', 'mono'), names));
    }
  }
  return out;
}

/// icons.score: how well a typed query matches an icon's names; 0: not at all.
int score(String query, List<String> names) {
  final q = fold(query);
  if (q.isEmpty) return 0;
  final compact = q.replaceAll(' ', '');
  final words = q.split(' ');
  var best = 0;
  for (final name in names) {
    final n = fold(name);
    if (n.isEmpty) continue;
    final nCompact = n.replaceAll(' ', '');
    final nWords = n.split(' ');
    int value;
    if (n == q || nCompact == compact) {
      value = 100;
    } else if (n.startsWith(q) || nCompact.startsWith(compact)) {
      final extra = nCompact.length - compact.length;
      value = 80 - (extra < 20 ? extra : 20);
    } else if (words.every((w) => nWords.any((w2) => w2.startsWith(w)))) {
      value = 60;
    } else if (compact.length >= 3 && nCompact.contains(compact)) {
      value = 40;
    } else if (words.length > 1 && words.where((w) => w.length >= 3).any(nWords.contains)) {
      value = 20;
    } else {
      value = 0;
    }
    if (value > best) best = value;
  }
  return best;
}

const _order = {'dashboard': 0, 'selfhst': 1, 'simple': 2};

/// icons.search: the best matching online icons.
List<Candidate> searchIcons(String query, String? command, List<(Candidate, List<String>)> entries,
    {int limit = maxOnlineResults}) {
  final terms = <(String, double)>[
    (query, 1.0),
    for (final a in aliases[fold(query)] ?? const <String>[]) (a, 0.9),
    if (command != null && fold(command) != fold(query)) ...[
      (command, 0.7),
      for (final a in aliases[fold(command)] ?? const <String>[]) (a, 0.6),
    ],
  ];
  final ranked = <(double, int, int, String, Candidate)>[];
  for (final (candidate, names) in entries) {
    var value = 0.0;
    for (final (term, weight) in terms) {
      final v = score(term, names) * weight;
      if (v > value) value = v;
    }
    if (value > 0) ranked.add((-value, _order[candidate.$1] ?? 9, candidate.$2.length, candidate.$2, candidate));
  }
  ranked.sort((a, b) {
    for (final c in [a.$1.compareTo(b.$1), a.$2.compareTo(b.$2), a.$3.compareTo(b.$3), a.$4.compareTo(b.$4)]) {
      if (c != 0) return c;
    }
    return 0;
  });
  final out = <Candidate>[];
  final seen = <String>{};
  for (final r in ranked) {
    if (!seen.add('${r.$5.$1}/${r.$5.$2}')) continue;
    out.add(r.$5);
    if (out.length >= limit) break;
  }
  return out;
}

bool looksLike(List<int> data, String kind) {
  if (kind == 'png') {
    const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    return data.length > 8 && List.generate(8, (i) => data[i]).toString() == sig.toString();
  }
  final head = utf8.decode(data.take(512).toList(), allowMalformed: true).trimLeft().toLowerCase();
  return head.startsWith('<svg') ||
      (head.startsWith('<?xml') && utf8.decode(data.take(4096).toList(), allowMalformed: true).toLowerCase().contains('<svg'));
}

/// Simple Icons are black shapes: paint them in the theme's text colour.
List<int> tint(List<int> svg, String? color) {
  if (color == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) return svg;
  final text = utf8.decode(svg, allowMalformed: true);
  return utf8.encode(text.replaceFirst(RegExp(r'<svg\b'), '<svg fill="$color"'));
}

final class IconChoices {
  IconChoices(this.session, this.store);
  final Session session;
  final ConfigStore store;

  String get iconDir {
    final env = session.environment;
    final data = env['XDG_DATA_HOME']?.isNotEmpty == true ? env['XDG_DATA_HOME']! : p.join(session.home, '.local/share');
    return p.join(data, 'maprisma-launcher/icons');
  }

  String get cacheDir => p.join(session.home, '.cache/maprisma-launcher');

  /// A theme icon name, or a file of ours in [iconDir].
  bool validValue(String value) =>
      _name.hasMatch(value) || (p.isAbsolute(value) && p.dirname(value) == iconDir && _name.hasMatch(p.basename(value)));

  Map<String, String> load() {
    final data = store.readJson('icons.json');
    if (data is! Map) return {};
    return {
      for (final e in data.entries.take(maxOverrides))
        if (e.key is String && (e.key as String).isNotEmpty && (e.key as String).length <= 300 && e.value is String && validValue(e.value as String))
          e.key as String: e.value as String,
    };
  }

  void save(Map<String, String> overrides) => store.writeJson('icons.json', overrides);

  List<String> _curl(String url, {int timeout = iconTimeout, int max = maxIconBytes}) => [
    session.which('curl') ?? 'curl', '--silent', '--fail', '--proto', '=https', '--max-redirs', '0',
    '--max-time', '$timeout', '--max-filesize', '$max', '--', url,
  ];

  Future<Uint8List?> fetch(String url, String kind) async {
    if (!_url.hasMatch(url) || url.contains('..') || session.which('curl') == null) return null;
    final data = await readBoundedBytes(_curl(url), maxBytes: maxIconBytes, timeout: const Duration(seconds: iconTimeout + 2));
    if (data == null || data.isEmpty || !looksLike(data, kind == 'png' ? 'png' : 'svg')) return null;
    return data;
  }

  /// One collection's entries: the cached list while younger than a week,
  /// else fetched again (the old copy when that fails).
  Future<List<(Candidate, List<String>)>> loadIndex(String key) async {
    final dir = p.join(cacheDir, 'icon-index');
    final file = p.join(dir, '$key.json');
    var raw = Posix.instance.readRegular(file, maxIndexBytes, follow: false);
    bool fresh;
    try {
      fresh = raw != null && DateTime.now().difference(File(file).statSync().modified) < indexMaxAge;
    } on FileSystemException {
      fresh = false;
    }
    if (!fresh && session.which('curl') != null) {
      final data = await readBoundedBytes(
        _curl(indexes[key]!, timeout: indexTimeout, max: maxIndexBytes),
        maxBytes: maxIndexBytes,
        timeout: const Duration(seconds: indexTimeout + 2),
      );
      if (data != null) {
        try {
          jsonDecode(utf8.decode(data));
          Directory(dir).createSync(recursive: true);
          ConfigStore(session, dir: dir).writeJson('$key.json', jsonDecode(utf8.decode(data)));
          raw = data;
        } on Object {
          // keep the old copy
        }
      }
    }
    if (raw == null) return [];
    try {
      return indexEntries(key, jsonDecode(utf8.decode(raw)));
    } on FormatException {
      return [];
    }
  }

  Future<List<Candidate>> online(String query, String? command) async {
    final entries = <(Candidate, List<String>)>[];
    for (final key in indexes.keys) {
      entries.addAll(await loadIndex(key));
    }
    return searchIcons(query, command, entries);
  }

  /// download: the candidate's data, trying the other format where the CDN
  /// lacks a file; Simple Icons tinted.
  Future<(Uint8List, String)?> download(Candidate c, String? color) async {
    var (collection, slug, url, kind) = c;
    var data = await fetch(url, kind);
    if (data == null && (collection == 'dashboard' || collection == 'selfhst') && (kind == 'svg' || kind == 'png')) {
      final other = kind == 'svg' ? 'png' : 'svg';
      url = '${url.substring(0, url.length - '$kind/$slug.$kind'.length)}$other/$slug.$other';
      kind = other;
      data = await fetch(url, kind);
    }
    if (data == null) return null;
    return (kind == 'mono' ? Uint8List.fromList(tint(data, color)) : data, kind == 'png' ? '.png' : '.svg');
  }

  /// A downloaded icon kept for [desktopId]; its path.
  String storeFile(String desktopId, List<int> data, String extension) {
    Directory(iconDir).createSync(recursive: true);
    final name = '${sha256.convert(utf8.encode(desktopId)).toString().substring(0, 16)}${extension == '.png' ? '.png' : '.svg'}';
    final path = p.join(iconDir, name);
    final tmp = p.join(iconDir, '.$name.$pid.tmp');
    try {
      File(tmp).deleteSync();
    } on FileSystemException {
      // none
    }
    if (!Posix.instance.writeNewPrivate(tmp, data)) throw FileSystemException('Could not save the icon', path);
    File(tmp).renameSync(path);
    return path;
  }

  /// A preview of an online candidate, in the cache (shown before choosing).
  Future<String?> preview(Candidate c, String? color) async {
    final got = await download(c, color);
    if (got == null) return null;
    final dir = p.join(cacheDir, 'icon-previews');
    Directory(dir).createSync(recursive: true);
    final path = p.join(dir, '${sha256.convert(utf8.encode(c.$3)).toString().substring(0, 16)}${got.$2}');
    File(path).writeAsBytesSync(got.$1, flush: true);
    return path;
  }
}
