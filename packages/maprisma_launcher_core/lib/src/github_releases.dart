/// Explicit GitHub requests use release metadata, never AI-generated commands.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'desktop_entries.dart';
import 'search_terms.dart';

String? githubQuery(String request) {
  // Other actions mentioning a repository must keep their existing meaning.
  if (RegExp(r'^\s*(?:remove|uninstall|hide|unhide|update|explain)\b', caseSensitive: false).hasMatch(request)) {
    return null;
  }
  final url = RegExp(r'https://github\.com/([\w.-]+/[\w.-]+)', caseSensitive: false).firstMatch(request);
  if (url != null) return url[1]!.replaceFirst(RegExp(r'\.git$'), '');
  if (request.contains('://')) return null;
  final source = RegExp(r'\bgithub\b', caseSensitive: false).firstMatch(request);
  if (source == null) return null;
  // Preserve the topic of a sentence such as "list the artcraft apps", rather
  // than taking only the final word before "from GitHub".
  final words = request
      .replaceRange(source.start, source.end, ' ')
      .replaceAll(RegExp(r'[?!:,]'), ' ')
      .trim()
      .split(RegExp(r'\s+'));
  const grammar = {
    'can',
    'could',
    'would',
    'you',
    'please',
    'i',
    'want',
    'to',
    'list',
    'show',
    'me',
    'find',
    'search',
    'for',
    'the',
    'a',
    'an',
    'install',
    'download',
    'get',
    'apps',
    'app',
    'applications',
    'application',
    'repositories',
    'repository',
    'repos',
    'projects',
    'from',
    'on',
    'in',
    'at',
    'of',
  };
  final topic = words.where((w) => !grammar.contains(w.toLowerCase())).join(' ');
  return RegExp(r'^[\w .+/-]{1,120}$').hasMatch(topic) ? topic : null;
}

final class GithubLookupFailure implements Exception {
  const GithubLookupFailure(this.status);
  final int status;
  @override
  String toString() => 'GitHub returned HTTP $status';
}

typedef GithubFetch = Future<Map<String, dynamic>> Function(String path);

final class GithubReleases {
  GithubReleases({GithubFetch? fetch, this.cacheDuration = const Duration(minutes: 5)}) : _fetchSource = fetch ?? _get;
  final GithubFetch _fetchSource;
  final Duration cacheDuration;
  final _cache = <String, ({DateTime at, Map<String, dynamic> value})>{};
  Future<Map<String, dynamic>> _fetch(String path) async {
    final cached = _cache[path];
    if (cached != null && DateTime.now().difference(cached.at) < cacheDuration) return cached.value;
    final value = await _fetchSource(path);
    if (_cache.length >= 40) _cache.remove(_cache.keys.first);
    _cache[path] = (at: DateTime.now(), value: value);
    return value;
  }

  static Future<Map<String, dynamic>> _get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(Uri.parse('https://api.github.com$path'));
        request.headers.set('User-Agent', 'Maprisma-Launcher');
        request.headers.set('Accept', 'application/vnd.github+json');
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200) {
          throw GithubLookupFailure(response.statusCode);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const HttpException('GitHub response too large');
          }
        }
        return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> search(
    String query, {
    String? architecture,
    Iterable<String> suggestions = const [],
  }) async {
    final repos = <Map>[];
    if (RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(query)) {
      repos.add(await _fetch('/repos/$query'));
    } else {
      for (final term in searchTerms(query, suggestions: suggestions)) {
        final found = (await _fetch(
          '/search/repositories?q=${Uri.encodeQueryComponent('$term in:name,description')}&per_page=5',
        ))['items'];
        if (found is List) {
          for (final repo in found.whereType<Map>()) {
            if (!repos.any((r) => r['full_name'] == repo['full_name'])) repos.add(repo);
          }
        }
      }
    }
    final terms = searchTerms(query, suggestions: suggestions);
    final ranked = [for (var i = 0; i < repos.length; i++) (repo: repos[i], index: i)]
      ..sort((a, b) {
        final score = searchRank(
          '${a.repo['name'] ?? a.repo['full_name']?.split('/').last ?? ''}',
          terms,
        ).compareTo(searchRank('${b.repo['name'] ?? b.repo['full_name']?.split('/').last ?? ''}', terms));
        return score != 0 ? score : a.index.compareTo(b.index);
      });
    final out = <Map<String, dynamic>>[];
    final arch =
        architecture ??
        (Abi.current() == Abi.linuxArm64
            ? 'arm64'
            : Abi.current() == Abi.linuxX64
            ? 'x64'
            : 'unsupported');
    for (final entry in ranked.take(5)) {
      final repo = entry.repo;
      if (repo['archived'] == true || repo['disabled'] == true) {
        continue;
      }
      final name = repo['full_name'];
      if (name is! String || !RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(name)) {
        continue;
      }
      final result = <String, dynamic>{
        'manager': 'github',
        'package': name,
        'name': repo['name'] ?? name,
        'description': repo['description'] ?? '',
        'repository': 'https://github.com/$name',
        'installable': false,
      };
      // A repository is still a useful listing result without an installer.
      out.add(result);
      Map release;
      try {
        release = await _fetch('/repos/$name/releases/latest');
      } on GithubLookupFailure catch (e) {
        if (e.status == 404) continue; // No published release.
        rethrow; // Rate limits and service failures are not "nothing found".
      }
      if (release['draft'] == true || release['prerelease'] == true) continue;
      for (final asset in release['assets'] as List? ?? []) {
        if (asset is! Map) continue;
        final file = asset['name'], digest = asset['digest'], url = asset['browser_download_url'];
        if (file is! String || !RegExp(r'^[\w.+-]+\.AppImage$').hasMatch(file)) {
          continue;
        }
        final lower = file.toLowerCase();
        final matches = arch == 'x64'
            ? RegExp(r'x86_64|amd64|x64').hasMatch(lower)
            : arch == 'arm64' && RegExp(r'aarch64|arm64').hasMatch(lower);
        if (!matches || digest is! String || !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest)) {
          continue;
        }
        final uri = url is String ? Uri.tryParse(url) : null;
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host != 'github.com' ||
            uri.hasQuery ||
            uri.hasFragment ||
            !uri.path.startsWith('/$name/releases/download/')) {
          continue;
        }
        result.addAll({
          'installable': true,
          'version': release['tag_name'] ?? '',
          'repository': 'https://github.com/$name',
          'url': url,
          'asset': file,
          'sha256': digest.substring(7),
        });
        break;
      }
    }
    return out;
  }
}

/// Download privately, verify, and atomically publish without replacing files.
/// This only installs the AppImage; it does not execute it.
List<String>? githubInstall(Session session, Map found, List<String> terminal) {
  if (found['installable'] != true) return null;
  final curl = session.which('curl'), sha = session.which('sha256sum');
  if (curl == null || sha == null) return null;
  final repo = found['package'] as String;
  final destination = p.join(session.home, 'Applications', '${repo.replaceAll('/', '-')}-${found['asset']}');
  return [
    ...terminal,
    'sh',
    '-c',
    r'''set -eu
mkdir -p -- "$1"
tmp=$(mktemp -d "$1/.maprisma-download.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
"$5" --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 600 --max-filesize 2147483648 --output "$tmp/app" -- "$2"
printf '%s  %s\n' "$3" "$tmp/app" | "$6" --check -
chmod 755 "$tmp/app"
ln -- "$tmp/app" "$4"
''',
    'github-install',
    p.dirname(destination),
    found['url'] as String,
    found['sha256'] as String,
    destination,
    curl,
    sha,
  ];
}
