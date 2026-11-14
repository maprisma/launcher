/// Updates for AppImages with embedded GitHub release update information.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:path/path.dart' as p;

import 'appimages.dart';
import 'bounded.dart';
import 'desktop_entries.dart';
import 'origins.dart' show programPath;
import 'posix.dart';

final _safePart = RegExp(r'^[A-Za-z0-9_.-]{1,100}$');
final _safeAsset = RegExp(r'^[A-Za-z0-9_.+-]{1,200}\.AppImage$');
final _updateInfo = RegExp(
  r'gh-releases-zsync\|([A-Za-z0-9_.-]{1,100})\|([A-Za-z0-9_.-]{1,100})\|([A-Za-z0-9_.-]{1,100})\|([A-Za-z0-9_.*+-]{1,200}\.AppImage\.zsync)',
);

/// An update must not place files in a directory another account can change.
bool privateUpdateDirectory(String path) {
  try {
    // A sandbox may map root's uid to an overflow uid. Trust the owner of /.
    final rootOwner = Posix.instance.owner('/');
    if (rootOwner == null) return false;
    for (var dir = p.normalize(p.absolute(path)); ; dir = p.dirname(dir)) {
      final stat = Directory(dir).statSync();
      final owner = Posix.instance.owner(dir);
      if (stat.type != FileSystemEntityType.directory || owner == null) {
        return false;
      }
      if (stat.mode & 0x12 != 0 && !(owner == rootOwner && stat.mode & 0x200 != 0)) {
        return false;
      }
      if (owner != rootOwner && owner != Posix.instance.uid) return false;
      if (dir == p.dirname(dir)) break;
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

bool absentWithoutFollowingLinks(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.notFound;

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
  String oldFile, {
  String? installedVersion,
  String? installedSha256,
}) {
  final tag = json['tag_name'];
  if (tag is! String || !_safePart.hasMatch(tag) || tag == '..') return null;
  final assets = json['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is! Map) continue;
    final filename = asset['name'];
    if (filename is! String ||
        !_safeAsset.hasMatch(filename) ||
        !_matchesPattern(filename, source.pattern)) {
      continue;
    }
    final current = installedVersion == '' ? null : installedVersion ?? appImageVersion(oldFile);
    final available =
        appImageVersion(filename) ??
        RegExp(r'^v?(\d+(?:\.\d+)+)').firstMatch(tag)?[1];
    final url = asset['browser_download_url'];
    final digest = asset['digest'];
    if (url !=
            'https://github.com/${source.owner}/${source.repo}/releases/download/$tag/$filename' ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      continue;
    }
    final sha = digest.substring(7).toLowerCase();
    if (installedSha256 == sha) continue;
    // Moving release channels often keep one asset name and a nonnumeric tag.
    // Without the installed file's digest there is no reliable ordering.
    if (available == null &&
        (installedSha256 == null ||
            !(source.channel == tag || source.channel == 'latest'))) {
      continue;
    }
    if (current != null &&
        available != null &&
        compareVersionKeys(
              versionKey('App-$available'),
              versionKey('App-$current'),
            ) <=
            0) {
      continue;
    }
    return {
      'version': available ?? '',
      'installed': current ?? '',
      'filename': filename,
      'url': url,
      'sha256': sha,
      'owner': source.owner,
      'repo': source.repo,
      'channel': source.channel,
      'pattern': source.pattern,
      'tag': tag,
      'size': '${asset['size'] is int ? asset['size'] : ''}',
    };
  }
  return null;
}

final class AppImageUpdates {
  static final Set<String> _activePaths = {};
  AppImageUpdates(this.session, {this.sourceLookup, this.releaseLookup, this.download, this.place});
  final Session session;
  final Future<AppImageSource?> Function(String)? sourceLookup;
  final Future<Map<String, dynamic>?> Function(AppImageSource)? releaseLookup;
  final Future<({Stream<List<int>> bytes, int length})> Function(Uri)? download;
  final Future<bool> Function(String from, String to)? place;

  Future<bool> _place(String from, String to) async {
    if (place != null) return place!(from, to);
    return (await Process.run('/usr/bin/ln', ['--', from, to])).exitCode == 0;
  }

  String _versionFile(String path) => '$path.maprisma-version';
  ({String? version, String? tag, String? sha256})? installedRecord(String path) {
    try {
      if (FileSystemEntity.typeSync(_versionFile(path), followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final bytes = Posix.instance.readRegular(_versionFile(path), 512);
      if (bytes == null) return null;
      final value = utf8.decode(bytes).trim();
      if (RegExp(r'^\d+(?:\.\d+)+$').hasMatch(value)) {
        return (version: value, tag: null, sha256: null);
      }
      final parsed = jsonDecode(value);
      if (parsed is! Map || parsed['version'] is! String ||
          parsed['tag'] is! String || parsed['sha256'] is! String) {
        return null;
      }
      final version = parsed['version'] as String;
      final tag = parsed['tag'] as String;
      final sha = parsed['sha256'] as String;
      if (version.isNotEmpty && !RegExp(r'^\d+(?:\.\d+)+$').hasMatch(version)) return null;
      if (!_safePart.hasMatch(tag) || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) return null;
      return (version: version.isEmpty ? null : version, tag: tag, sha256: sha);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  String? installedVersion(String path) => installedRecord(path)?.version;

  Future<String?> _fileDigest(String path) async {
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file || stat.size > 512 * 1024 * 1024) return null;
      final hash = AccumulatorSink<Digest>();
      final sink = sha256.startChunkedConversion(hash);
      var size = 0;
      final started = DateTime.now();
      await for (final chunk in File(path).openRead().timeout(const Duration(seconds: 15))) {
        size += chunk.length;
        if (size > 512 * 1024 * 1024 ||
            DateTime.now().difference(started) > const Duration(minutes: 1)) {
          return null;
        }
        sink.add(chunk);
      }
      sink.close();
      return hash.events.single.toString();
    } on Object {
      return null;
    }
  }

  Future<AppImageSource?> _source(String path) async {
    if (sourceLookup != null) return sourceLookup!(path);
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
  Future<Map<String, dynamic>> check(Map<String, Map> apps) async {
    final wanted = <String, (String, AppImageSource)>{};
    final unknown = <String, String>{};
    final entries = await Future.wait(
      apps.entries.map((entry) async {
        final path = programPath(entry.value, session);
        if (path == null ||
            !p.isWithin(session.home, path) ||
            !path.toLowerCase().endsWith('.appimage') ||
            !privateUpdateDirectory(p.dirname(path))) {
          return null;
        }
        final source = await _source(path);
        if (source == null) {
          unknown[entry.key] = 'No embedded update source';
          return null;
        }
        return (entry.key, path, source);
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
          if (releaseLookup != null) return (key, await releaseLookup!(source));
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
          final body = BytesBuilder(copy: false);
          final started = DateTime.now();
          await for (final chunk in response.timeout(const Duration(seconds: 8))) {
            if (body.length + chunk.length > 1024 * 1024 ||
                DateTime.now().difference(started) > const Duration(seconds: 20)) {
              return (key, null);
            }
            body.add(chunk);
          }
          final json = jsonDecode(utf8.decode(body.takeBytes()));
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
      final updates = <String, Map<String, String>>{};
      for (final e in wanted.entries) {
        final json = releases[sourceKey(e.value.$2)];
        if (json == null) {
          unknown[e.key] = 'Release check unavailable';
          continue;
        }
        final record = installedRecord(e.value.$1);
        final tagVersion = RegExp(r'^v?(\d+(?:\.\d+)+)').firstMatch('${json['tag_name']}')?[1];
        final matching = json['assets'] is List
            ? (json['assets'] as List).where((asset) => asset is Map &&
                asset['name'] is String &&
                _matchesPattern(asset['name'] as String, e.value.$2.pattern)).toList()
            : const [];
        final versionless = tagVersion == null && matching.any((asset) =>
            appImageVersion(asset['name'] as String) == null);
        final digest = versionless ? await _fileDigest(e.value.$1) : null;
        final release = appImageRelease(json, e.value.$2, p.basename(e.value.$1),
          installedVersion: record == null ? null : record.version ?? '',
          installedSha256: digest);
        if (release != null) {
          updates[e.key] = {...release, 'path': e.value.$1};
        } else if (versionless && digest == null) {
          unknown[e.key] = 'Installed checksum unavailable';
        } else if (matching.isNotEmpty &&
            !matching.any((asset) => asset is Map && asset['digest'] == 'sha256:$digest')) {
          final current = record == null ? appImageVersion(p.basename(e.value.$1)) : record.version;
          final available = tagVersion ?? appImageVersion(matching.first['name'] as String);
          if (current == null || available == null ||
              compareVersionKeys(versionKey('App-$available'), versionKey('App-$current')) > 0) {
            unknown[e.key] = 'Release cannot be verified';
          }
        }
      }
      return {'updates': updates, 'unknown': unknown};
    } finally {
      client.close(force: true);
    }
  }

  Future<({Stream<List<int>> bytes, int length})> _openDownload(Uri uri) async {
    if (download != null) return download!(uri);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    client.userAgent = 'Maprisma Launcher';
    try {
      var current = uri;
      for (var hop = 0; hop <= 5; hop++) {
        if (current.scheme != 'https') {
          throw const FileSystemException('Insecure download redirect');
        }
        final request = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const FileSystemException('Invalid download redirect');
          }
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw const FileSystemException('Download failed');
        }
        if (response.contentLength > 512 * 1024 * 1024) {
          throw const FileSystemException('Download too large');
        }
        Stream<List<int>> body() async* {
          try {
            yield* response;
          } finally {
            client.close(force: true);
          }
        }

        return (bytes: body(), length: response.contentLength);
      }
      throw const FileSystemException('Too many download redirects');
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  /// Download and verify, then replace the binary at its stable path.
  Future<void> install(Map app, Map release, {void Function()? beforeChange}) async {
    final old = programPath(app, session);
    if (old == null) {
      throw const FileSystemException('Not an installed user AppImage');
    }
    if (!_activePaths.add(old)) {
      throw const FileSystemException('Update already running');
    }
    try {
      await _install(app, release, old, beforeChange);
    } finally {
      _activePaths.remove(old);
    }
  }

  Future<void> _install(Map app, Map release, String old, void Function()? beforeChange) async {
    if (!p.isWithin(session.home, old) ||
        !old.toLowerCase().endsWith('.appimage') ||
        !privateUpdateDirectory(p.dirname(old)) ||
        release['path'] != old) {
      throw const FileSystemException('Not an installed user AppImage');
    }
    final source = await _source(old);
    final filename = release['filename'];
    final tag = release['tag'];
    final record = installedRecord(old);
    final installedDigest = release['version'] == '' ? await _fileDigest(old) : null;
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
        !RegExp(r'^[a-f0-9]{64}$').hasMatch('${release['sha256']}')) {
      throw const FileSystemException('Invalid release');
    }
    final verified = appImageRelease({
      'tag_name': tag,
      'assets': [{
        'name': filename,
        'browser_download_url': release['url'],
        'digest': 'sha256:${release['sha256']}',
      }],
    }, source, p.basename(old),
      installedVersion: record == null ? null : record.version ?? '',
      installedSha256: installedDigest);
    if (verified == null || release['version'] != verified['version']) {
      throw const FileSystemException('Invalid release');
    }
    final downloadDir = await Directory(
      p.dirname(old),
    ).createTemp('.maprisma-update-');
    final part = File(p.join(downloadDir.path, 'download.part'));
    try {
      final response = await _openDownload(Uri.parse(release['url'] as String));
      if (response.length > 512 * 1024 * 1024) {
        throw const FileSystemException('Download failed');
      }
      final sink = part.openWrite();
      final hash = AccumulatorSink<Digest>();
      final digestSink = sha256.startChunkedConversion(hash);
      var bytes = 0;
      try {
        final started = DateTime.now();
        await for (final chunk in response.bytes.timeout(
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
      final marker = File(_versionFile(old));
      final markerBackup = File('${_versionFile(old)}.bak');
      final rotatedBackup = File(p.join(downloadDir.path, 'previous.bak'));
      final rotatedMarker = File(
        p.join(downloadDir.path, 'previous-version.bak'),
      );
      final nextMarker = File(p.join(downloadDir.path, 'next-version'));
      final nextVersion = release['version'];
      if (nextVersion is! String) {
        throw const FileSystemException('Invalid release version');
      }
      if (nextVersion.isNotEmpty) {
        if (!RegExp(r'^\d+(?:\.\d+)+$').hasMatch(nextVersion)) {
          throw const FileSystemException('Invalid release version');
        }
      }
      await nextMarker.writeAsString(jsonEncode({
        'version': nextVersion,
        'tag': tag,
        'sha256': release['sha256'],
      }), flush: true);
      var oldMoved = false;
      var newPlaced = false;
      var backupMoved = false;
      var markerBackupMoved = false;
      var markerMoved = false;
      var nextMarkerPlaced = false;
      try {
        for (final path in [marker.path, markerBackup.path]) {
          final type = FileSystemEntity.typeSync(path, followLinks: false);
          if (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.file) {
            throw const FileSystemException('Invalid update version record');
          }
        }
        beforeChange?.call();
        if (!absentWithoutFollowingLinks('$old.bak')) {
          if (FileSystemEntity.typeSync('$old.bak', followLinks: false) !=
              FileSystemEntityType.file) {
            throw const FileSystemException('Invalid previous version');
          }
          await File('$old.bak').rename(rotatedBackup.path);
          backupMoved = true;
        }
        if (await markerBackup.exists()) {
          await markerBackup.rename(rotatedMarker.path);
          markerBackupMoved = true;
        }
        await File(old).rename('$old.bak');
        oldMoved = true;
        if (!await _place(part.path, old)) {
          throw const FileSystemException('Could not place verified AppImage');
        }
        newPlaced = true;
        if (await marker.exists()) {
          await marker.rename(markerBackup.path);
          markerMoved = true;
        }
        if (await nextMarker.exists()) {
          await nextMarker.rename(marker.path);
          nextMarkerPlaced = true;
        }
        await part.delete();
      } on Object {
        if (newPlaced &&
            FileSystemEntity.typeSync(old, followLinks: false) == FileSystemEntityType.file &&
            await part.exists() &&
            await FileSystemEntity.identical(old, part.path)) {
          await File(old).delete();
        }
        if (oldMoved && await File('$old.bak').exists()) {
          if (await _place('$old.bak', old)) await File('$old.bak').delete();
        }
        if (nextMarkerPlaced && await marker.exists()) await marker.delete();
        if (markerMoved && await markerBackup.exists()) {
          await markerBackup.rename(marker.path);
        }
        if (backupMoved && await rotatedBackup.exists()) {
          await rotatedBackup.rename('$old.bak');
        }
        if (markerBackupMoved && await rotatedMarker.exists()) {
          await rotatedMarker.rename(markerBackup.path);
        }
        rethrow;
      }
    } finally {
      if (await downloadDir.exists()) await downloadDir.delete(recursive: true);
    }
  }

  bool canRestore(Map app) {
    final path = programPath(app, session);
    return path != null &&
        p.isWithin(session.home, path) &&
        privateUpdateDirectory(p.dirname(path)) &&
        FileSystemEntity.typeSync('$path.bak', followLinks: false) == FileSystemEntityType.file;
  }

  Future<void> restore(Map app, {void Function()? beforeChange}) async {
    final path = programPath(app, session);
    if (path == null || !canRestore(app)) {
      throw const FileSystemException('No previous version');
    }
    if (!_activePaths.add(path)) throw const FileSystemException('Update already running');
    try {
      beforeChange?.call();
      await _restore(path);
    } finally {
      _activePaths.remove(path);
    }
  }

  Future<void> _restore(String path) async {
    final temp = '$path.maprisma-restore-temp';
    if (!absentWithoutFollowingLinks(temp)) {
      throw const FileSystemException('Restore is already in progress');
    }
    final marker = File(_versionFile(path));
    final saved = File('${_versionFile(path)}.bak');
    final temporaryMarker = File('${marker.path}.tmp');
    for (final name in [marker.path, saved.path]) {
      final type = FileSystemEntity.typeSync(name, followLinks: false);
      if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) {
        throw const FileSystemException('Invalid update version record');
      }
    }
    if (!absentWithoutFollowingLinks(temporaryMarker.path)) {
      throw const FileSystemException('Restore is already in progress');
    }
    await File(path).rename(temp);
    var previousPlaced = false;
    try {
      await File('$path.bak').rename(path);
      previousPlaced = true;
      await File(temp).rename('$path.bak');
    } catch (_) {
      if (previousPlaced) await File(path).rename('$path.bak');
      if (await File(temp).exists()) await File(temp).rename(path);
      rethrow;
    }
    if (await marker.exists()) await marker.rename(temporaryMarker.path);
    if (await saved.exists()) await saved.rename(marker.path);
    if (await temporaryMarker.exists()) {
      await temporaryMarker.rename(saved.path);
    }
  }
}
