/// Downloaded AppImages are data until an explicit reviewed local install.
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'appimages.dart';
import 'desktop_entries.dart';
import 'posix.dart';

const maxDownloadedAppImageBytes = 2 * 1024 * 1024 * 1024;

String downloadsDirectory(Session session) {
  final bytes = Posix.instance.readRegular(
    p.join(session.home, '.config/user-dirs.dirs'),
    65536,
    follow: false,
  );
  if (bytes != null) {
    final match = RegExp(
      r'^XDG_DOWNLOAD_DIR="([^"\r\n]*)"\s*$',
      multiLine: true,
    ).firstMatch(utf8.decode(bytes, allowMalformed: true));
    if (match != null) {
      final path = match[1]!.replaceAll(r'$HOME', session.home);
      if (p.isAbsolute(path) &&
          !path.contains(r'$') &&
          !path.contains('`') &&
          !path.contains('\\')) {
        return path;
      }
    }
  }
  return p.join(session.home, 'Downloads');
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Map<String, dynamic>? _inspect(String path, int uid, {RandomAccessFile? copy}) {
  final sink = _DigestSink();
  final hash = sha256.startChunkedConversion(sink);
  var size = 0;
  final header = <int>[];
  final ok = Posix.instance.streamOwned(path, maxDownloadedAppImageBytes, uid, (
    chunk,
  ) {
    if (header.length < 11) header.addAll(chunk.take(11 - header.length));
    size += chunk.length;
    hash.add(chunk);
    copy?.writeFromSync(chunk);
  });
  hash.close();
  if (!ok) return null;
  final magic =
      header.length >= 11 &&
      header[0] == 127 &&
      header[1] == 69 &&
      header[2] == 76 &&
      header[3] == 70 &&
      header[8] == 65 &&
      header[9] == 73 &&
      header[10] == 2;
  final name = p.basename(path);
  return {
    'source': path,
    'size': size,
    'sha256': '${sink.value}',
    'uid': uid,
    'appimage':
        magic || name.endsWith('.AppImage') || name.endsWith('.appimage'),
  };
}

Future<List<Map<String, dynamic>>> downloadedAppImages(
  Session session, {
  int? uid,
}) async {
  final owner = uid ?? Posix.instance.uid;
  final result = <Map<String, dynamic>>[];
  final installed = <String>[];
  for (final dir in appImageDirectories(session)) {
    try {
      await for (final file in Directory(dir).list(followLinks: false)) {
        if (file is File) installed.add(file.path);
      }
    } on FileSystemException {
      continue;
    }
  }
  try {
    await for (final file in Directory(
      downloadsDirectory(session),
    ).list(followLinks: false).take(50)) {
      if (file is! File ||
          FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      if (installed.any((f) => p.basename(f) == p.basename(file.path))) {
        continue;
      }
      if (!file.path.endsWith('.AppImage') &&
          !file.path.endsWith('.appimage') &&
          !hasAppImageMagic(file.path)) {
        continue;
      }
      final info = _inspect(file.path, owner);
      if (info == null || info['appimage'] != true) continue;
      if (installed.any(
        (f) =>
            File(f).lengthSync() == info['size'] &&
            _inspect(f, owner)?['sha256'] == info['sha256'],
      )) {
        continue;
      }
      final filename = p.basename(file.path);
      result.add({
        ...info,
        'manager': 'local',
        'package': filename,
        'name': appImageBaseName(p.basenameWithoutExtension(filename)),
        'description': filename,
        'version': '',
        'installable': true,
        'installed': false,
      });
    }
  } on FileSystemException {
    // Missing or unreadable Downloads is an empty source.
  }
  return result;
}

Map<String, dynamic> localInstallPlan(Session session, Map found) => {
  ...found,
  'local': true,
  'argv': <String>[],
  'destination': p.join(
    session.home,
    'Applications',
    found['package'] as String,
  ),
  'command':
      '${found['source']}\n${found['size']} bytes\nSHA-256: ${found['sha256']}\n→ ${p.join(session.home, 'Applications', found['package'] as String)}',
};

void installLocalAppImage(Map plan) {
  final destination = plan['destination'] as String;
  final directory = Directory(p.dirname(destination))
    ..createSync(recursive: true);
  final staging = directory.createTempSync('.maprisma-');
  final file = File(p.join(staging.path, 'appimage'));
  try {
    final output = file.openSync(mode: FileMode.write);
    Map<String, dynamic>? current;
    try {
      current = _inspect(
        plan['source'] as String,
        plan['uid'] as int,
        copy: output,
      );
      output.flushSync();
    } finally {
      output.closeSync();
    }
    if (current == null ||
        current['size'] != plan['size'] ||
        current['sha256'] != plan['sha256']) {
      throw const FileSystemException('the file changed since the review');
    }
    final chmod = Process.runSync('/bin/chmod', ['755', file.path]);
    if (chmod.exitCode != 0) {
      throw const FileSystemException('Could not make AppImage executable');
    }
    if (!Posix.instance.renameNew(file.path, destination)) {
      final existing = _inspect(destination, plan['uid'] as int);
      if (existing == null ||
          existing['sha256'] != plan['sha256'] ||
          existing['size'] != plan['size']) {
        throw const FileSystemException('Destination already exists');
      }
    }
  } finally {
    staging.deleteSync(recursive: true);
  }
}
