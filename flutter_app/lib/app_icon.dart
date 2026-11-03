import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// An app's icon from the file the core found; a neutral glyph otherwise.
class AppIcon extends StatelessWidget {
  const AppIcon(this.file, {super.key, this.size = 32});
  final String? file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.apps, size: size * .8, color: Theme.of(context).colorScheme.onSurfaceVariant);
    final path = file;
    Widget child;
    if (path == null) {
      child = fallback;
    } else if (path.endsWith('.svg') || path.endsWith('.icon') && _isSvg(path)) {
      child = SvgPicture.file(
        File(path),
        width: size,
        height: size,
        placeholderBuilder: (_) => SizedBox(width: size, height: size),
      );
    } else {
      child = Image.file(
        File(path),
        width: size,
        height: size,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(child: child),
    );
  }
}

/// An AppImage's cached icon (*.icon) is a PNG or an SVG: its first bytes tell.
final _svgFiles = <String, bool>{};
bool _isSvg(String path) => _svgFiles.putIfAbsent(path, () {
  try {
    final file = File(path).openSync();
    try {
      final head = String.fromCharCodes(file.readSync(256)).trimLeft();
      return head.startsWith('<?xml') || head.startsWith('<svg');
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return false;
  }
});
