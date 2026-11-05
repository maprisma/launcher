/// Updates for AppImages with embedded GitHub release update information.
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:path/path.dart' as p;

import 'appimages.dart';
import 'bounded.dart';
import 'desktop_entries.dart';
import 'origins.dart' show programPath;

final _safePart = RegExp(r'^[A-Za-z0-9_.-]{1,100}$');
final _safeAsset = RegExp(r'^[A-Za-z0-9_.+-]{1,200}\.AppImage$');
final _updateInfo = RegExp(
  r'gh-releases-zsync\|([A-Za-z0-9_.-]{1,100})\|([A-Za-z0-9_.-]{1,100})\|([A-Za-z0-9_.-]{1,100})\|([A-Za-z0-9_.*+-]{1,200}\.AppImage\.zsync)',
);

/// An update must not place files in a directory another account can change.
bool privateUpdateDirectory(String path) {
  try {
    final stat = Directory(path).statSync();
    return stat.type == FileSystemEntityType.directory && stat.mode & 0x12 == 0;
  } on FileSystemException {
    return false;
  }
}

bool absentWithoutFollowingLinks(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;

/// GitHub publisher and AppImage asset pattern embedded in .upd_info.
typedef AppImageSource = ({
  String owner,
  String repo,
  String channel,
  String pattern,
});

AppImageSource? parseAppImageUpdateInfo(String? output) {
  final m = output == null ? null : _updateInfo.firstMatch(output);
  if (m == null || [m[1], m[2], m[3]].any((part) => part == '..')) return null;
  return (owner: m[1]!, repo: m[2]!, channel: m[3]!, pattern: m[4]!);
}

bool _matchesPattern(String filename, String pattern) {
  final escaped = RegExp.escape(pattern.replaceFirst(RegExp(r'\.zsync$'), ''));
  return RegExp(
    '^${escaped.replaceAll(r'\*', r'[A-Za-z0-9._+-]*')}\$',
  ).hasMatch(filename);
}

String? appImageVersion(String filename) {
  final words = appImageWords(p.basenameWithoutExtension(filename)).$2;
  for (final word in words) {
    final match = RegExp(r'^v?(\d+(?:\.\d+)+)').firstMatch(word);
    if (match != null) return match[1];
  }
  return null;
}

bool newerAppImage(String installed, String available) {
  final oldStem = p.basenameWithoutExtension(installed);
  final newStem = p.basenameWithoutExtension(available);
  final a = versionKey(oldStem), b = versionKey(newStem);
  return a.$1.isNotEmpty &&
      b.$1.isNotEmpty &&
      nameKey(appImageBaseName(oldStem)) ==
          nameKey(appImageBaseName(newStem)) &&
      compareVersionKeys(b, a) > 0;
}

/// Only an asset matching the embedded pattern and its SHA-256 is accepted.
Map<String, String>? appImageRelease(
  Map<String, dynamic> json,
  AppImageSource source,
  String oldFile,
) {
  final tag = json['tag_name'];
  if (tag is! String || !_safePart.hasMatch(tag) || tag == '..') return null;
  final assets = json['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is! Map) continue;
    final filename = asset['name'];
    if (filename is! String ||
        !_safeAsset.hasMatch(filename) ||
        !_matchesPattern(filename, source.pattern) ||
        !newerAppImage(oldFile, filename)) {
      continue;
    }
    final url = asset['browser_download_url'];
    final digest = asset['digest'];
    if (url !=
            'https://github.com/${source.owner}/${source.repo}/releases/download/$tag/$filename' ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      continue;
    }
    return {
      'version': appImageVersion(filename) ?? '',
      'installed': appImageVersion(oldFile) ?? '',
      'filename': filename,
      'url': url,
      'sha256': digest.substring(7).toLowerCase(),
      'owner': source.owner,
      'repo': source.repo,
      'channel': source.channel,
      'pattern': source.pattern,
      'tag': tag,
    };
  }
  return null;
}

final class AppImageUpdates {
  AppImageUpdates(this.session);
  final Session session;

  Future<AppImageSource?> _source(String path) async {
    final readelf = session.which('readelf');
    if (readelf == null) return null;
    final out = await readBoundedText(
      [readelf, '-p', '.upd_info', path],
      maxBytes: 4096,
      timeout: const Duration(seconds: 5),
      environment: session.environment,
    );
    return parseAppImageUpdateInfo(out);
  }

  /// Entry key to release details. A failed network request leaves that app unknown.
  Future<Map<String, Map<String, String>>> check(Map<String, Map> apps) async {
    final wanted = <String, (String, AppImageSource)>{};
    final entries = await Future.wait(
      apps.entries.map((entry) async {
        final path = programPath(entry.value, session);
        if (path == null ||
            !p.isWithin(session.home, path) ||
            !path.toLowerCase().endsWith('.appimage') ||
            !privateUpdateDirectory(p.dirname(path))) {
          return null;
        }
        final desktop = entry.value['desktop_path'];
        if (desktop is String &&
            desktop.isNotEmpty &&
            !p.isWithin(
              p.join(session.home, '.local/share/applications'),
              desktop,
            )) {
          return null;
        }
        final source = await _source(path);
        return source == null ? null : (entry.key, path, source);
      }),
    );
    for (final entry in entries) {
      if (entry != null) wanted[entry.$1] = (entry.$2, entry.$3);
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.userAgent = 'Maprisma Launcher';
    try {
      // Share one request per repository and release channel.
      String sourceKey(AppImageSource s) => '${s.owner}/${s.repo}/${s.channel}';
      Future<(String, Map<String, dynamic>?)> fetch(String key) async {
        final source = wanted.values
            .firstWhere((v) => sourceKey(v.$2) == key)
            .$2;
        try {
          final route = source.channel == 'latest'
              ? '/repos/${source.owner}/${source.repo}/releases/latest'
              : '/repos/${source.owner}/${source.repo}/releases/tags/${source.channel}';
          final uri = Uri.https('api.github.com', route);
          final request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 8));
          request.headers.set(
            HttpHeaders.acceptHeader,
            'application/vnd.github+json',
          );
          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          if (response.statusCode != 200 ||
              response.contentLength > 1024 * 1024) {
            return (key, null);
          }
          final body = await utf8.decoder
              .bind(response)
              .join()
              .timeout(const Duration(seconds: 8));
          if (body.length > 1024 * 1024) return (key, null);
          final json = jsonDecode(body);
          if (json is Map<String, dynamic>) return (key, json);
        } on Object {
          /* Offline or rate limited: leave the result unknown. */
        }
        return (key, null);
      }

      final fetched = await Future.wait(
        wanted.values.map((v) => sourceKey(v.$2)).toSet().map(fetch),
      );
      final releases = {for (final (key, release) in fetched) key: release};
      return {
        for (final e in wanted.entries)
          if (releases[sourceKey(e.value.$2)] case final json?)
            if (appImageRelease(json, e.value.$2, p.basename(e.value.$1))
                case final release?)
              e.key: {...release, 'path': e.value.$1},
      };
    } finally {
      client.close(force: true);
    }
  }

  /// Download and verify before changing either the launcher or its file.
  Future<void> install(Map app, Map release) async {
    final old = programPath(app, session);
    if (old == null ||
        !p.isWithin(session.home, old) ||
        !old.toLowerCase().endsWith('.appimage') ||
        !privateUpdateDirectory(p.dirname(old)) ||
        release['path'] != old) {
      throw const FileSystemException('Not an installed user AppImage');
    }
    final source = await _source(old);
    final filename = release['filename'];
    final tag = release['tag'];
    if (source == null ||
        filename is! String ||
        !_safeAsset.hasMatch(filename) ||
        tag is! String ||
        !_safePart.hasMatch(tag) ||
        release['owner'] != source.owner ||
        release['repo'] != source.repo ||
        release['channel'] != source.channel ||
        release['pattern'] != source.pattern ||
        !_matchesPattern(filename, source.pattern) ||
        release['url'] !=
            'https://github.com/${source.owner}/${source.repo}/releases/download/$tag/$filename' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch('${release['sha256']}') ||
        !newerAppImage(p.basename(old), filename)) {
      throw const FileSystemException('Invalid release');
    }
    final desktop = app['desktop_path'];
    final ownDesktop = p.join(session.home, '.local/share/applications');
    if (desktop is! String ||
        (desktop.isNotEmpty &&
            (!p.isWithin(ownDesktop, desktop) ||
                !privateUpdateDirectory(p.dirname(desktop)) ||
                FileSystemEntity.typeSync(desktop, followLinks: false) != FileSystemEntityType.file ||
                File(desktop).resolveSymbolicLinksSync() != p.normalize(desktop)))) {
      throw const FileSystemException('No editable desktop launcher');
    }
    final oldText = desktop.isEmpty ? null : await File(desktop).readAsString();
    if (oldText != null && !oldText.contains(old)) {
      throw const FileSystemException(
        'Launcher does not reference this AppImage',
      );
    }
    final destination = p.join(p.dirname(old), filename);
    if (!absentWithoutFollowingLinks(destination) || !absentWithoutFollowingLinks('$old.bak')) {
      throw const FileSystemException('Existing update or backup needs review');
    }
    final downloadDir = await Directory(p.dirname(old)).createTemp('.maprisma-update-');
    final part = File(p.join(downloadDir.path, 'download.part'));
    final desktopDir = oldText == null ? null : await Directory(p.dirname(desktop)).createTemp('.maprisma-update-');
    final desktopPart = desktopDir == null ? null : File(p.join(desktopDir.path, 'launcher.desktop'));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    client.userAgent = 'Maprisma Launcher';
    try {
      final request = await client.getUrl(Uri.parse(release['url'] as String));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200 ||
          response.contentLength > 512 * 1024 * 1024) {
        throw const FileSystemException('Download failed');
      }
      final sink = part.openWrite();
      final hash = AccumulatorSink<Digest>();
      final digestSink = sha256.startChunkedConversion(hash);
      var bytes = 0;
      try {
        final started = DateTime.now();
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (DateTime.now().difference(started) > const Duration(minutes: 9)) {
            throw const FileSystemException('Download timed out');
          }
          bytes += chunk.length;
          if (bytes > 512 * 1024 * 1024) {
            throw const FileSystemException('Download too large');
          }
          sink.add(chunk);
          digestSink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      digestSink.close();
      if (hash.events.single.toString() != release['sha256'] ||
          bytes < 1024 * 1024) {
        throw const FileSystemException('Release checksum mismatch');
      }
      final chmod = await Process.run('/usr/bin/chmod', ['755', part.path]);
      if (chmod.exitCode != 0) {
        throw const FileSystemException('Could not mark AppImage executable');
      }
      await part.rename(destination);
      try {
        // The desktop entry now points to the new version. Keep the old binary
        // as a rollback file outside the AppImage scanner's filename pattern.
        if (oldText != null) {
          await desktopPart!.writeAsString(
            oldText.replaceAll(old, destination),
            flush: true,
          );
          await desktopPart.rename(desktop);
        }
        await File(old).rename('$old.bak');
      } on Object {
        if (oldText != null) {
          await File(desktop).writeAsString(oldText, flush: true);
        }
        if (await File(destination).exists()) await File(destination).delete();
        rethrow;
      }
    } finally {
      client.close(force: true);
      if (await downloadDir.exists()) await downloadDir.delete(recursive: true);
      if (desktopDir != null && await desktopDir.exists()) await desktopDir.delete(recursive: true);
    }
  }
}
