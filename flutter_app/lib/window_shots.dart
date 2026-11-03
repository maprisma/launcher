import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'i18n.dart';

/// F12: a picture of App Manager's own window and its note (as Maprisma's
/// WindowShots), in ~/Pictures/MaprismaLauncher or the folder chosen in Settings,
/// while the setting screenshot_key is on (default).
final class WindowShots {
  WindowShots(this.folder);
  final String folder;

  static WindowShots fromEnvironment(Map<String, String> environment) =>
      WindowShots('${environment['HOME'] ?? ''}/Pictures/MaprismaLauncher');

  /// maprisma-launcher-2026-11-03-08-26-31.png, then -2 within the same second.
  String pathFor(DateTime time) {
    String two(int n) => '$n'.padLeft(2, '0');
    final stem =
        'maprisma-launcher-${time.year}-${two(time.month)}-${two(time.day)}'
        '-${two(time.hour)}-${two(time.minute)}-${two(time.second)}';
    var path = '$folder/$stem.png';
    for (var n = 2; File(path).existsSync(); n++) {
      path = '$folder/$stem-$n.png';
    }
    return path;
  }

  Future<String> save(Uint8List png, DateTime time) async {
    await Directory(folder).create(recursive: true);
    final path = pathFor(time);
    await File(path).writeAsBytes(png, flush: true);
    return path;
  }

  /// Into the folder chosen in Settings; a folder that cannot be written
  /// loses no picture, it goes to the default one.
  Future<String> saveTo(String? chosen, Uint8List png, DateTime time) async {
    if (chosen == null) return save(png, time);
    try {
      return await WindowShots(chosen).save(png, time);
    } on FileSystemException {
      return save(png, time);
    }
  }

  /// The note goes next to its picture, with the same name; no note, no file.
  Future<void> note(String picture, String text) async {
    if (text.trim().isEmpty) return;
    final stem = picture.substring(0, picture.length - '.png'.length);
    await File('$stem.txt').writeAsString('${text.trim()}\n', flush: true);
  }
}

/// After F12: where the picture went, and an optional note.
class ShotNote extends StatefulWidget {
  const ShotNote(this.path, {super.key});
  final String path;
  @override
  State<ShotNote> createState() => _ShotNoteState();
}

class _ShotNoteState extends State<ShotNote> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(trf('Screenshot saved: {0}', [widget.path])),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('screenshot-note'),
          controller: _note,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('What is wrong? (optional)')),
          onSubmitted: (text) => Navigator.pop(context, text),
        ),
      ],
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context, _note.text), child: Text(tr('Done')))],
  );
}
