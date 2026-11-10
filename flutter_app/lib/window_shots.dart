import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';

import 'i18n.dart';

/// F12: a picture of Maprisma Launcher's own window and its note (as Maprisma Playground's), in
/// ~/Pictures/MaprismaLauncher (XDG_PICTURES_DIR) or the folder chosen in Settings, while the
/// setting screenshot_key is on (default). The files themselves: the core's screenshot.dart
/// (a private folder, new 0600 files, never over an older one).

/// Why a picture or a note could not be saved, in the system's own words.
String shotError(Object error) => switch (error) {
  FileSystemException(:final osError?) => osError.message,
  FileSystemException(:final message) => message,
  _ => '$error',
};

/// The window drew nothing to take a picture of.
final class NoPicture implements Exception {
  @override
  String toString() => tr('The window drew nothing.');
}

/// "Screenshot saved": where, and a field for what is wrong. Done, Enter, Esc and a click beside it
/// all close it with the text typed (the field's controller lives and goes with the dialog).
class ScreenshotNoteDialog extends StatefulWidget {
  const ScreenshotNoteDialog({super.key, required this.path});
  final String path;
  @override
  State<ScreenshotNoteDialog> createState() => _ScreenshotNoteDialogState();
}

class _ScreenshotNoteDialogState extends State<ScreenshotNoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _note.text);

  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _done(); // Esc or a click beside it: the note is kept too
    },
    child: AlertDialog(
      title: Text(tr('Screenshot saved'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(trf('Saved as {0}', [homeShort(widget.path)])),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('screenshot-note'),
              controller: _note,
              autofocus: true,
              maxLength: screenshotNoteLimit,
              decoration: InputDecoration(hintText: tr('What is wrong? (optional)'), counterText: ''),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: _done, child: Text(tr('Done')))],
    ),
  );
}
