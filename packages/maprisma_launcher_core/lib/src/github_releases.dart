/// Explicit GitHub requests use release metadata, never AI-generated commands.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'desktop_entries.dart';

String? githubQuery(String request) {
  // Other actions mentioning a repository must keep their existing meaning.
  if (RegExp(r'^\s*(?:remove|uninstall|hide|unhide|update|explain)\b', caseSensitive: false).hasMatch(request)) return null;
  final url = RegExp(
    r'https://github\.com/([\w.-]+/[\w.-]+)',
    caseSensitive: false,
  ).firstMatch(request);
  if (url != null) return url[1]!.replaceFirst(RegExp(r'\.git$'), '');
  return RegExp(
    r'([\w.-]+(?:/[\w.-]+)?)\s+(?:from|on)\s+github\b',
    caseSensitive: false,
  ).firstMatch(request)?[1];
}

typedef GithubFetch = Future<Map<String, dynamic>> Function(String path);

final class GithubReleases {
  GithubReleases({GithubFetch? fetch}) : _fetch = fetch ?? _get;
  final GithubFetch _fetch;
  static Future<Map<String, dynamic>> _get(String path) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri.parse('https://api.github.com$path'),
        );
        request.headers.set('User-Agent', 'Maprisma-Launcher');
        request.headers.set('Accept', 'application/vnd.github+json');
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const HttpException('GitHub lookup failed');
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
  }) async {
    final repos = query.contains('/')
        ? [await _fetch('/repos/$query')]
        : ((await _fetch(
                    '/search/repositories?q=${Uri.encodeQueryComponent('$query in:name')}&per_page=5',
                  ))['items']
                  as List? ??
              []);
    final out = <Map<String, dynamic>>[];
    final arch =
        architecture ??
        (Abi.current() == Abi.linuxArm64
            ? 'arm64'
            : Abi.current() == Abi.linuxX64
            ? 'x64'
            : 'unsupported');
    for (final repo in repos) {
      if (repo is! Map || repo['archived'] == true || repo['disabled'] == true) {
        continue;
      }
      final name = repo['full_name'];
      if (name is! String || !RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(name)) {
        continue;
      }
      Map release;
      try {
        release = await _fetch('/repos/$name/releases/latest');
      } on Object {
        continue;
      }
      if (release['draft'] == true || release['prerelease'] == true) continue;
      for (final asset in release['assets'] as List? ?? []) {
        if (asset is! Map) continue;
        final file = asset['name'],
            digest = asset['digest'],
            url = asset['browser_download_url'];
        if (file is! String || !RegExp(r'^[\w.+-]+\.AppImage$').hasMatch(file)) {
          continue;
        }
        final lower = file.toLowerCase();
        final matches = arch == 'x64'
            ? RegExp(r'x86_64|amd64|x64').hasMatch(lower)
            : arch == 'arm64' && RegExp(r'aarch64|arm64').hasMatch(lower);
        if (!matches ||
            digest is! String ||
            !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest)) {
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
        out.add({
          'manager': 'github',
          'package': name,
          'name': repo['name'] ?? name,
          'description': repo['description'] ?? '',
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
  final curl = session.which('curl'), sha = session.which('sha256sum');
  if (curl == null || sha == null) return null;
  final repo = found['package'] as String;
  final destination = p.join(
    session.home,
    'Applications',
    '${repo.replaceAll('/', '-')}-${found['asset']}',
  );
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
