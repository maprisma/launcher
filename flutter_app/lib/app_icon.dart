import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

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

/// An app's icon with its marks, as gnome-launcher draws them: the run dot
/// (bottom right), an update dot (top right), ★ when newly installed (top
/// left), a crossed-out eye when hidden (bottom left).
class MarkedIcon extends StatelessWidget {
  const MarkedIcon(
    this.file, {
    super.key,
    this.size = 32,
    this.running = false,
    this.update = false,
    this.fresh = false,
    this.hidden = false,
  });
  final String? file;
  final double size;
  final bool running, update, fresh, hidden;

  @override
  Widget build(BuildContext context) {
    final marks = markColors(context);
    final dot = (size / 4).clamp(7.0, 12.0);
    Widget mark(Color color) => Container(
      width: dot,
      height: dot,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1.5),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: AppIcon(file, size: size)),
          if (running) Positioned(right: -2, bottom: -2, child: mark(marks.running)),
          if (update) Positioned(right: -2, top: -2, child: mark(marks.update)),
          if (fresh)
            Positioned(
              left: -3,
              top: -5,
              child: Icon(Icons.star_rounded, size: dot + 6, color: marks.fresh),
            ),
          if (hidden)
            Positioned(
              left: -2,
              bottom: -2,
              child: Icon(Icons.visibility_off, size: dot + 3, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
