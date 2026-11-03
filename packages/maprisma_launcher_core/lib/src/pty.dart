/// A program in a pseudo terminal, for the app's own terminal page (installs,
/// uninstalls and system updates run inside Maprisma Launcher instead of an
/// outside terminal window). The terminal is opened through libc (FFI):
/// posix_openpt, a non-blocking master, the size by TIOCSWINSZ. The program
/// runs under `setsid -w -c` with the terminal as stdin/stdout/stderr and as
/// its controlling terminal, so sudo asks for the password right there.
/// Output is kept bounded; input is written as the terminal takes it.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'desktop_entries.dart';

final class _Libc {
  static final _lib = DynamicLibrary.open('libc.so.6');
  static final openpt = _lib.lookupFunction<Int Function(Int), int Function(int)>('posix_openpt');
  static final grantpt = _lib.lookupFunction<Int Function(Int), int Function(int)>('grantpt');
  static final unlockpt = _lib.lookupFunction<Int Function(Int), int Function(int)>('unlockpt');
  static final ptsname = _lib.lookupFunction<Int Function(Int, Pointer<Utf8>, Size), int Function(int, Pointer<Utf8>, int)>(
    'ptsname_r',
  );
  static final read = _lib.lookupFunction<IntPtr Function(Int, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>(
    'read',
  );
  static final write = _lib
      .lookupFunction<IntPtr Function(Int, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>('write');
  static final close = _lib.lookupFunction<Int Function(Int), int Function(int)>('close');
  static final ioctl = _lib.lookupFunction<Int Function(Int, UnsignedLong, Pointer<Uint16>), int Function(int, int, Pointer<Uint16>)>(
    'ioctl',
  );
  static final errno = _lib.lookupFunction<Pointer<Int> Function(), Pointer<Int> Function()>('__errno_location');
}

const _oRdwr = 0x2, _oNoctty = 0x100, _oNonblock = 0x800, _oCloexec = 0x80000;
const _tiocswinsz = 0x5414;
const _eagain = 11, _eintr = 4;

final class PtySession {
  PtySession._(this.id, this._master, this._process, this.title, this.command);

  final String id;
  final int _master;
  final Process _process;

  /// What the page shows: a title and the command line it runs.
  final String title, command;

  final _out = BytesBuilder(copy: false);
  int? exitCode;
  bool _closed = false;
  Timer? _poll;

  /// At most this much output waits for the page; older output is dropped.
  static const maxPending = 1024 * 1024;

  bool get ended => exitCode != null;

  /// Starts [argv] in a new terminal of [cols] × [rows]; null when this
  /// system cannot (no setsid, no pseudo terminals).
  static Future<PtySession?> start(
    String id,
    List<String> argv,
    Session session, {
    required String title,
    required String command,
    int cols = 100,
    int rows = 30,
  }) async {
    final setsid = session.which('setsid');
    final sh = session.which('sh');
    if (setsid == null || sh == null || argv.isEmpty) return null;
    final master = _Libc.openpt(_oRdwr | _oNoctty | _oNonblock | _oCloexec);
    if (master < 0) return null;
    String? slave;
    final name = calloc<Uint8>(256);
    try {
      if (_Libc.grantpt(master) == 0 && _Libc.unlockpt(master) == 0 && _Libc.ptsname(master, name.cast(), 256) == 0) {
        slave = name.cast<Utf8>().toDartString();
      }
    } finally {
      calloc.free(name);
    }
    if (slave == null || !RegExp(r'^/dev/pts/[0-9]+$').hasMatch(slave)) {
      _Libc.close(master);
      return null;
    }
    _setSize(master, cols, rows);
    Process process;
    try {
      // The terminal becomes stdin/stdout/stderr, then setsid gives the
      // program a session of its own with it as the controlling terminal;
      // -w waits and passes the program's exit code on. argv stays argv.
      process = await Process.start(
        sh,
        ['-c', 'tty="\$1"; shift; exec "\$0" -w -c "\$@" <"\$tty" >"\$tty" 2>&1', setsid, slave, ...argv],
        environment: {...session.environment, 'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
        includeParentEnvironment: false,
      );
    } on ProcessException {
      _Libc.close(master);
      return null;
    }
    final pty = PtySession._(id, master, process, title, command);
    process.stdout.drain<void>().ignore();
    process.stderr.drain<void>().ignore();
    process.stdin.close().ignore();
    process.exitCode.then((code) {
      pty.exitCode = code;
      pty._pump(); // What is still in the terminal.
    });
    pty._poll = Timer.periodic(const Duration(milliseconds: 25), (_) => pty._pump());
    return pty;
  }

  static void _setSize(int fd, int cols, int rows) {
    final size = calloc<Uint16>(4);
    try {
      size[0] = rows.clamp(2, 1000);
      size[1] = cols.clamp(2, 1000);
      _Libc.ioctl(fd, _tiocswinsz, size);
    } finally {
      calloc.free(size);
    }
  }

  void resize(int cols, int rows) {
    if (!_closed) _setSize(_master, cols, rows);
  }

  void _pump() {
    if (_closed) return;
    final buffer = calloc<Uint8>(65536);
    try {
      for (var i = 0; i < 16; i++) {
        final n = _Libc.read(_master, buffer, 65536);
        if (n > 0) {
          _out.add(Uint8List.fromList(buffer.asTypedList(n)));
          continue;
        }
        if (n < 0 && _Libc.errno().value == _eintr) continue;
        break; // EAGAIN: nothing now; EIO: the program and its children are gone.
      }
    } finally {
      calloc.free(buffer);
    }
    if (_out.length > maxPending) {
      // Keep the newer half, from a line start (not inside a character or
      // an escape sequence), after a reset of any open control string.
      final all = _out.takeBytes();
      var from = all.length - maxPending ~/ 2;
      final newline = all.indexOf(0x0a, from);
      if (newline >= 0 && newline < all.length - 1) from = newline + 1;
      _out
        ..add(const [0x1b, 0x5c, 0x0d, 0x0a]) // ST, then a new line
        ..add(Uint8List.sublistView(all, from));
    }
    if (ended) _poll?.cancel();
  }

  /// The output since the last call. Once the program ended and its last
  /// output is taken, the terminal itself closes.
  Uint8List take() {
    _pump();
    // Ended: read what is left in the terminal before it closes.
    for (var before = -1; ended && !_closed && _out.length != before;) {
      before = _out.length;
      _pump();
    }
    final out = _out.takeBytes();
    if (ended && !_closed) {
      _poll?.cancel();
      _closed = true;
      _Libc.close(_master);
    }
    return out;
  }

  /// Writes what the terminal takes now; the count written.
  int write(List<int> bytes) {
    if (_closed || ended || bytes.isEmpty) return 0;
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final n = _Libc.write(_master, buffer, bytes.length);
      if (n < 0) {
        final e = _Libc.errno().value;
        return e == _eagain || e == _eintr ? 0 : -1;
      }
      return n;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Closes the terminal: a program still running gets a hangup.
  void close() {
    if (_closed) return;
    _poll?.cancel();
    _closed = true;
    _Libc.close(_master);
    if (!ended) _process.kill(ProcessSignal.sighup);
  }
}
