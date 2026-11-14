import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// The few libc calls Dart lacks: a bounded, non-blocking read of a regular
/// file (checked on the opened descriptor) and access(2).
final class Posix {
  Posix._();
  static final instance = Posix._();

  static final _lib = DynamicLibrary.open('libc.so.6');
  static final _open = _lib
      .lookupFunction<
        Int Function(Pointer<Utf8>, Int, Uint32),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  static final _close = _lib
      .lookupFunction<Int Function(Int), int Function(int)>('close');
  static final _read = _lib
      .lookupFunction<
        IntPtr Function(Int, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  static final _write = _lib
      .lookupFunction<
        IntPtr Function(Int, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  static final _fsync = _lib
      .lookupFunction<Int Function(Int), int Function(int)>('fsync');
  static final _access = _lib
      .lookupFunction<
        Int Function(Pointer<Utf8>, Int),
        int Function(Pointer<Utf8>, int)
      >('access');
  static final _statx = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Int, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
      >('statx');
  static final _flock = _lib
      .lookupFunction<Int Function(Int, Int), int Function(int, int)>('flock');
  static final _uid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'getuid',
  );

  static const _rdonly = 0,
      _nonBlock = 0x800,
      _noCtty = 0x100,
      _cloexec = 0x80000,
      _noFollow = 0x20000,
      _emptyPath = 0x1000;

  int get uid => _uid();

  /// Owner of a path, following links, from statx(2).
  int? owner(String path) {
    final buffer = calloc<Uint8>(256);
    try {
      final ok = _withPath(
        path,
        (name) => _statx(-100, name, 0, 0xfff, buffer) == 0,
      );
      if (ok != true) return null;
      return ByteData.sublistView(
        buffer.asTypedList(256),
      ).getUint32(20, Endian.host);
    } finally {
      calloc.free(buffer);
    }
  }

  /// Create [path] new (O_EXCL, never through a symlink) as 0600 and write
  /// [bytes] to it, synced. False when it exists or a write fails.
  bool writeNewPrivate(String path, List<int> bytes) {
    final fd =
        _withPath(
          path,
          (name) =>
              _open(name, 0x1 | 0x40 | 0x80 | _noFollow | _cloexec, 0x180),
        ) ??
        -1;
    if (fd < 0) return false;
    final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var done = 0;
      while (done < bytes.length) {
        final n = _write(fd, buffer + done, bytes.length - done);
        if (n <= 0) return false;
        done += n;
      }
      return _fsync(fd) == 0;
    } finally {
      calloc.free(buffer);
      _close(fd);
    }
  }

  /// Stream a descriptor checked for regular type, size and owner; never follow links.
  bool streamOwned(
    String path,
    int cap,
    int uid,
    void Function(List<int>) chunk,
  ) {
    final fd =
        _withPath(
          path,
          (name) => _open(
            name,
            _rdonly | _nonBlock | _noCtty | _cloexec | _noFollow,
            0,
          ),
        ) ??
        -1;
    if (fd < 0) return false;
    final buffer = calloc<Uint8>(65536);
    try {
      final info = _fstat(fd);
      if (info == null ||
          info.$1 & 0xf000 != 0x8000 ||
          info.$2 > cap ||
          info.$3 != uid) {
        return false;
      }
      var total = 0;
      while (true) {
        final n = _read(fd, buffer, 65536);
        if (n < 0) return false;
        if (n == 0) return total == info.$2;
        total += n;
        if (total > cap) return false;
        chunk(Uint8List.fromList(buffer.asTypedList(n)));
      }
    } finally {
      calloc.free(buffer);
      _close(fd);
    }
  }

  /// Linux renameat2(RENAME_NOREPLACE): never overwrite a competing destination.
  bool renameNew(String source, String target) {
    final rename = _lib
        .lookupFunction<
          Int Function(Int, Pointer<Utf8>, Int, Pointer<Utf8>, Uint32),
          int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
        >('renameat2');
    return _withPath(
          source,
          (a) =>
              _withPath(target, (b) => rename(-100, a, -100, b, 1) == 0) ??
              false,
        ) ??
        false;
  }

  /// Bounded tail of an owned regular file, checked on its no-follow descriptor.
  (Uint8List, int)? readOwnedTail(String path, int cap) {
    final fd = _withPath(path, (name) => _open(name,
        _rdonly | _nonBlock | _noFollow | _cloexec, 0)) ?? -1;
    if (fd < 0) return null;
    try {
      final info = _fstat(fd);
      if (info == null || info.$1 & 0xf000 != 0x8000 || info.$3 != uid) return null;
      final start = max(0, info.$2 - cap);
      if (_seek(fd, start, 0) != start) return null;
      final size = info.$2 - start;
      final buffer = calloc<Uint8>(max(1, size));
      try {
        var done = 0;
        while (done < size) {
          final n = _read(fd, buffer + done, size - done);
          if (n <= 0) return null;
          done += n;
        }
        return (Uint8List.fromList(buffer.asTypedList(size)), info.$2);
      } finally { calloc.free(buffer); }
    } finally { _close(fd); }
  }
  static final _seek = _lib.lookupFunction<Int64 Function(Int, Int64, Int), int Function(int, int, int)>('lseek');

  /// Append one complete record through a no-follow, owned regular descriptor.
  bool appendPrivate(String path, List<int> bytes) {
    final fd = _withPath(path, (name) => _open(name,
        0x1 | 0x40 | 0x400 | _nonBlock | _noFollow | _cloexec, 0x180)) ?? -1;
    if (fd < 0) return false;
    final buffer = calloc<Uint8>(bytes.length);
    try {
      final info = _fstat(fd);
      if (info == null || info.$1 & 0xf000 != 0x8000 || info.$3 != uid) return false;
      if (_fchmod(fd, 0x180) != 0) return false;
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var done = 0;
      while (done < bytes.length) {
        final n = _write(fd, buffer + done, bytes.length - done);
        if (n <= 0) return false;
        done += n;
      }
      return true;
    } finally {
      calloc.free(buffer);
      _close(fd);
    }
  }
  static final _fchmod = _lib.lookupFunction<Int Function(Int, Uint32), int Function(int, int)>('fchmod');

  T? _withPath<T>(String path, T Function(Pointer<Utf8>) action) {
    if (path.isEmpty || path.contains('\x00')) return null;
    final native = path.toNativeUtf8();
    try {
      return action(native);
    } finally {
      calloc.free(native);
    }
  }

  /// access(path, X_OK) as Python's os.access.
  bool executable(String path) =>
      _withPath(path, (name) => _access(name, 1) == 0) ?? false;

  /// When [path] was created (seconds), else its change time; null when
  /// it does not exist (Python's `stat -c %W`, then st_ctime).
  int? birthTime(String path) {
    final buffer = calloc<Uint8>(256);
    try {
      final ok = _withPath(
        path,
        (name) => _statx(-100, name, 0, 0xfff, buffer) == 0,
      );
      if (ok != true) return null;
      final data = ByteData.sublistView(buffer.asTypedList(256));
      final mask = data.getUint32(0, Endian.host);
      final born = data.getInt64(80, Endian.host);
      if (mask & 0x800 != 0 && born > 0) return born;
      return data.getInt64(96, Endian.host);
    } finally {
      calloc.free(buffer);
    }
  }

  /// Run [body] holding flock(LOCK_EX) on [lockPath] (created 0600, never
  /// through a symlink): the same lock the plugins' Python plugin_ai takes.
  T withFlock<T>(String lockPath, T Function() body) {
    final fd =
        _withPath(
          lockPath,
          (name) => _open(name, 0x1 | 0x40 | _nonBlock | _noFollow | _cloexec, 0x180),
        ) ??
        -1;
    if (fd < 0) throw FileSystemException('Could not open the lock', lockPath);
    try {
      final info = _fstat(fd);
      if (info == null || info.$1 & 0xf000 != 0x8000 || info.$3 != uid || _fchmod(fd, 0x180) != 0) {
        throw FileSystemException('Invalid lock file', lockPath);
      }
      if (_flock(fd, 2) != 0) {
        throw FileSystemException('Could not lock', lockPath);
      }
      return body();
    } finally {
      _close(fd);
    }
  }

  /// The owner's uid of [path] (following links unless [follow] is false), or null.
  int? ownerOf(String path, {bool follow = true}) {
    final buffer = calloc<Uint8>(256);
    try {
      // AT_SYMLINK_NOFOLLOW = 0x100: a link's own owner.
      final ok = _withPath(
        path,
        (name) => _statx(-100, name, follow ? 0 : 0x100, 0x8, buffer) == 0,
      );
      if (ok != true) return null;
      return ByteData.sublistView(
        buffer.asTypedList(256),
      ).getUint32(20, Endian.host);
    } finally {
      calloc.free(buffer);
    }
  }

  /// (mode, size, uid) of an open descriptor.
  (int, int, int)? _fstat(int fd) {
    final buffer = calloc<Uint8>(256);
    final empty = ''.toNativeUtf8();
    try {
      if (_statx(fd, empty, _emptyPath, 0x7ff, buffer) != 0) return null;
      final data = ByteData.sublistView(buffer.asTypedList(256));
      return (
        data.getUint16(28, Endian.host),
        data.getUint64(40, Endian.host),
        data.getUint32(20, Endian.host),
      );
    } finally {
      calloc.free(buffer);
      calloc.free(empty);
    }
  }

  /// The bytes of a regular file of at most [cap] bytes, else null:
  /// O_NONBLOCK so a FIFO cannot block, the type and size checked on the
  /// opened descriptor, the read stops after cap + 1 bytes. With [prefix],
  /// larger regular files are allowed but only their first [cap] bytes are read.
  Uint8List? readRegular(
    String path,
    int cap, {
    bool follow = true,
    bool prefix = false,
  }) {
    final fd =
        _withPath(
          path,
          (name) => _open(
            name,
            _rdonly | _nonBlock | _noCtty | _cloexec | (follow ? 0 : _noFollow),
            0,
          ),
        ) ??
        -1;
    if (fd < 0) return null;
    try {
      final info = _fstat(fd);
      if (info == null ||
          info.$1 & 0xf000 != 0x8000 ||
          (!prefix && info.$2 > cap)) {
        return null;
      }
      final buffer = calloc<Uint8>(min(cap + 1, 65536));
      final bytes = BytesBuilder(copy: false);
      try {
        while (bytes.length < (prefix ? cap : cap + 1)) {
          final count = _read(
            fd,
            buffer,
            min((prefix ? cap : cap + 1) - bytes.length, 65536),
          );
          if (count < 0) return null;
          if (count == 0) break;
          bytes.add(Uint8List.fromList(buffer.asTypedList(count)));
        }
      } finally {
        calloc.free(buffer);
      }
      return bytes.length > cap ? null : bytes.takeBytes();
    } finally {
      _close(fd);
    }
  }
}

/// shutil.which: the first executable, non-directory [program] on PATH.
String? which(String program, Map<String, String> environment) {
  if (program.isEmpty || program.contains('\x00')) return null;
  if (program.contains('/')) {
    return Posix.instance.executable(program) &&
            !FileSystemEntity.isDirectorySync(program)
        ? program
        : null;
  }
  final path = environment['PATH'] ?? '/bin:/usr/bin';
  for (final dir in path.split(':')) {
    final candidate = '${dir.isEmpty ? '.' : dir}/$program';
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound &&
        !FileSystemEntity.isDirectorySync(candidate) &&
        Posix.instance.executable(candidate)) {
      return candidate;
    }
  }
  return null;
}

final _chmod = DynamicLibrary.open('libc.so.6').lookupFunction<Int Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');
bool chmodPath(String path, int mode) {
  final name = path.toNativeUtf8();
  try { return _chmod(name, mode) == 0; } finally { calloc.free(name); }
}
