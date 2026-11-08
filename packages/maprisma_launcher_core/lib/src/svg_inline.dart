/// Icons that colour themselves through a stylesheet (Breeze's
/// `.ColorScheme-Text { color: … }` with `fill:currentColor`): Flutter's SVG
/// renderer ignores `<style>`, so such icons draw as nothing. They are shown
/// from a cached copy with the colours written into the shapes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_entries.dart';
import 'posix.dart';

final _style = RegExp(r'<style\b[^>]*>([\s\S]*?)</style>', caseSensitive: false);
final _rule = RegExp(r'\.ColorScheme-([A-Za-z]+)\s*\{[^}]*?color\s*:\s*(#[0-9a-fA-F]{3,8})', caseSensitive: false);
final _tag = RegExp(r'<[a-zA-Z][^<>]*>');
final _class = RegExp(r'''class\s*=\s*["']([^"']*)["']''');

/// [svg] with every `currentColor` replaced by its class's colour, and the
/// stylesheet removed; null when it has no stylesheet (nothing to do).
/// [theme]: the launcher's colours — Text follows `foreground`, Accent and
/// Highlight follow `accent`, so the icons fit light and dark themes.
String? inlineSvgColors(String svg, Map<String, String> theme) {
  final style = _style.firstMatch(svg);
  if (style == null) return null;
  final colors = <String, String>{
    for (final m in _rule.allMatches(style[1]!)) m[1]!.toLowerCase(): m[2]!,
  };
  if (theme['foreground'] case final fg?) colors['text'] = fg;
  if (theme['accent'] case final accent?) {
    colors['accent'] = accent;
    colors['highlight'] = accent;
  }
  final fallback = colors['text'] ?? '#888888';
  final body = svg.replaceRange(style.start, style.end, '');
  return body.replaceAllMapped(_tag, (m) {
    final tag = m[0]!;
    if (!tag.contains('currentColor')) return tag;
    String? color;
    for (final c in (_class.firstMatch(tag)?[1] ?? '').split(RegExp(r'\s+'))) {
      if (c.startsWith('ColorScheme-')) color ??= colors[c.substring(12).toLowerCase()];
    }
    return tag.replaceAll('currentColor', color ?? fallback);
  });
}

/// The icon file to show for [path]: a cached copy with inlined colours when
/// it needs one, else [path] itself.
String drawableIcon(String path, Map<String, String> theme, Session session) {
  if (!path.endsWith('.svg')) return path;
  final bytes = Posix.instance.readRegular(path, 512 * 1024);
  if (bytes == null) return path;
  final text = utf8.decode(bytes, allowMalformed: true);
  if (!text.contains('<style') && !text.contains('<STYLE')) return path;
  final inlined = inlineSvgColors(text, theme);
  if (inlined == null) return path;
  final cache = session.environment['XDG_CACHE_HOME']?.isNotEmpty == true
      ? session.environment['XDG_CACHE_HOME']!
      : p.join(session.home, '.cache');
  final key = _fnv('$path|${theme['foreground']}|${theme['accent']}|${text.length}');
  final out = p.join(cache, 'maprisma-launcher', 'inline-icons', '$key.svg');
  try {
    final file = File(out);
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
      final temp = File('$out.$pid.tmp')..writeAsStringSync(inlined);
      temp.renameSync(out);
    }
    return out;
  } on FileSystemException {
    return path;
  }
}

String _fnv(String text) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(text)) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
