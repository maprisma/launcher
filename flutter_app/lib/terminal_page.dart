import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'main.dart' show PopupGuard;
import 'theme.dart';

/// Installs, uninstalls and system updates run here, in the app, instead of
/// an outside terminal window (the app stays open; sudo asks for the
/// password in this terminal). The core decides what runs (term.start); this
/// page shows the output and passes the keys on.
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.core, required this.start, required this.title});
  final CoreCall core;

  /// term.start's parameters: the action and what it is about.
  final Map<String, dynamic> start;
  final String title;

  /// Pages running a command now: the window does not go back to the list
  /// when shown again, and a popup does not hide when it loses the focus.
  static final running = ValueNotifier<int>(0);

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// Runs [start] in the app's terminal; the exit code, or null when it could
/// not start there (then [outside] runs it the old way, in a terminal window).
Future<int?> runInTerminal(
  BuildContext context,
  CoreCall core,
  Map<String, dynamic> start,
  String title, {
  Future<void> Function()? outside,
}) async {
  final result = await Navigator.of(context).push<Object?>(
    MaterialPageRoute(
      builder: (_) => TerminalPage(core: core, start: start, title: title),
    ),
  );
  if (result == #outside) {
    await outside?.call();
    return null;
  }
  return result as int?;
}

class _TerminalPageState extends State<TerminalPage> {
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  final keys = FocusNode();
  final closeFocus = FocusNode();
  final _decoder = const Utf8Decoder(allowMalformed: true);
  late final _sink = _decoder.startChunkedConversion(_TerminalSink(terminal));
  final _input = <int>[];
  String? id;
  String command = '';
  String? error;
  int? exitCode;
  bool ended = false;
  bool _counted = false;
  Timer? _poll;
  bool _busy = false;
  (int, int)? _size;

  @override
  void initState() {
    super.initState();
    terminal.onOutput = (text) {
      if (ended || error != null) return;
      _input.addAll(utf8.encode(text));
      _pump();
    };
    terminal.onResize = (cols, rows, _, _) {
      _size = (cols, rows);
      _pump();
    };
    TerminalPage.running.value++;
    PopupGuard.hold();
    _counted = true;
    _start();
  }

  void _release() {
    if (!_counted) return;
    _counted = false;
    TerminalPage.running.value--;
    PopupGuard.release();
  }

  Future<void> _start() async {
    try {
      final r = await widget.core('term.start', {
        ...widget.start,
        'cols': terminal.viewWidth > 2 ? terminal.viewWidth : 100,
        'rows': terminal.viewHeight > 2 ? terminal.viewHeight : 30,
      });
      if (!mounted) return;
      setState(() {
        id = r['id'] as String;
        command = '${r['command'] ?? ''}';
      });
      _poll = Timer.periodic(const Duration(milliseconds: 40), (_) => _pump());
      keys.requestFocus();
      _pump(); // The real size and the first output at once.
    } on Object catch (e) {
      if (!mounted) return;
      _release();
      if (e is! ServiceError) {
        setState(() => error = tr('The terminal stopped.'));
        return;
      }
      // No terminal here (or nothing that needs one): the old way.
      if (e.code == 'no_pty' || e.code == 'not_terminal') {
        Navigator.pop(context, #outside);
        return;
      }
      setState(() => error = trf('That did not work ({0}).', [e.code]));
    }
  }

  Future<void> _pump() async {
    final id = this.id;
    if (id == null || _busy || !mounted || ended || error != null) return;
    _busy = true;
    try {
      final size = _size;
      if (size != null && !ended) {
        _size = null;
        await widget.core('term.resize', {'id': id, 'cols': size.$1, 'rows': size.$2});
      }
      if (_input.isNotEmpty && !ended) {
        final chunk = _input.length > 4096 ? _input.sublist(0, 4096) : List<int>.of(_input);
        final r = await widget.core('term.write', {'id': id, 'data': base64Encode(chunk)});
        final accepted = r['accepted'] as int? ?? 0;
        if (accepted < 0 || r['ended'] == true) {
          _input.clear();
        } else {
          _input.removeRange(0, accepted.clamp(0, chunk.length));
        }
      }
      final r = await widget.core('term.read', {'id': id});
      final data = base64Decode(r['data'] as String? ?? '');
      if (data.isNotEmpty) _sink.add(data);
      if (r['ended'] == true && !ended && mounted) {
        _poll?.cancel();
        _release();
        setState(() {
          ended = true;
          exitCode = r['code'] as int?;
        });
        _onEnd();
      }
    } on ServiceError catch (e) {
      // The core lost this terminal (or the core itself is gone): stop here,
      // so the page can be left and the popup hides again.
      _stopWith(trf('That did not work ({0}).', [e.code]));
    } on Object {
      _stopWith(tr('The terminal stopped.'));
    } finally {
      _busy = false;
    }
  }

  void _stopWith(String message) {
    _poll?.cancel();
    _release();
    if (mounted) setState(() => error = message);
    _onEnd();
  }

  /// Done: the keys leave the terminal, so Esc and Enter close the page.
  void _onEnd() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) closeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _release();
    final id = this.id;
    if (id != null) widget.core('term.close', {'id': id}).ignore();
    keys.dispose();
    closeFocus.dispose();
    controller.dispose();
    super.dispose();
  }

  void _close() => Navigator.pop(context, exitCode);

  /// Ctrl+C for the running program (the safe way to stop pacman & co.).
  void _interrupt() {
    _input.add(3);
    _pump();
  }

  TerminalTheme _theme(ColorScheme scheme) {
    const d = TerminalThemes.defaultTheme;
    return TerminalTheme(
      cursor: scheme.primary,
      selection: scheme.primary.withValues(alpha: .35),
      foreground: scheme.onSurface,
      background: scheme.surfaceContainerLowest,
      black: d.black,
      white: d.white,
      red: d.red,
      green: d.green,
      yellow: d.yellow,
      blue: d.blue,
      magenta: d.magenta,
      cyan: d.cyan,
      brightBlack: d.brightBlack,
      brightRed: d.brightRed,
      brightGreen: d.brightGreen,
      brightYellow: d.brightYellow,
      brightBlue: d.brightBlue,
      brightMagenta: d.brightMagenta,
      brightCyan: d.brightCyan,
      brightWhite: d.brightWhite,
      searchHitBackground: d.searchHitBackground,
      searchHitBackgroundCurrent: d.searchHitBackgroundCurrent,
      searchHitForeground: d.searchHitForeground,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    final (statusText, statusColor, statusIcon) = switch ((error, ended, exitCode)) {
      (final String e, _, _) => (e, scheme.error, Icons.error_outline),
      (_, false, _) when id == null => (tr('Starting…'), scheme.onSurfaceVariant, Icons.hourglass_empty),
      (_, false, _) => (tr('Running… type here when it asks (e.g. your password).'), scheme.primary, null),
      (_, true, 0) => (tr('Done.'), marks.running, Icons.check_circle_outline),
      (_, true, final int? code) when code == 130 => (
        tr('Stopped.'),
        scheme.onSurfaceVariant,
        Icons.stop_circle_outlined,
      ),
      (_, true, final int? code) => (trf('Failed (exit code {0}).', [code ?? '?']), scheme.error, Icons.error_outline),
    };
    return PopScope(
      // While it runs, leaving would hang up the program in the middle.
      canPop: ended || error != null,
      child: Scaffold(
        body: Focus(
          // Esc closes a finished page (while running, Esc belongs to the program).
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && (ended || error != null)) {
              _close();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 16, 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: ended || error != null ? _close : null,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: Text(tr('Back')),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (!ended && id != null)
                      OutlinedButton.icon(
                        onPressed: _interrupt,
                        icon: const Icon(Icons.stop, size: 16),
                        label: Text(tr('Stop (Ctrl+C)')),
                      ),
                    if (ended || error != null)
                      FilledButton(focusNode: closeFocus, onPressed: _close, child: Text(tr('Close'))),
                  ],
                ),
              ),
              if (command.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: SelectableText(
                    command,
                    maxLines: 1,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: Row(
                  children: [
                    if (statusIcon != null)
                      Icon(statusIcon, size: 16, color: statusColor)
                    else
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(corners(context).clamp(0, 12)),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: TerminalView(
                    terminal,
                    controller: controller,
                    focusNode: keys,
                    autofocus: true,
                    theme: _theme(scheme),
                    textStyle: const TerminalStyle(fontSize: 13),
                    onSecondaryTapDown: (_, _) async {
                      final selected = controller.selection;
                      if (selected != null) {
                        await Clipboard.setData(ClipboardData(text: terminal.buffer.getText(selected)));
                        controller.clearSelection();
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Decoded output into the terminal (multi-byte characters may arrive split).
class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);
  final Terminal terminal;
  @override
  void add(String data) => terminal.write(data);
  @override
  void close() {}
}
