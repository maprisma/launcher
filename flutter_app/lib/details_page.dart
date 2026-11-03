import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'core_call.dart';
import 'i18n.dart';

/// Details (launcher.py open_details_page / details_rows): what an app is,
/// where it comes from, its package; paths and the website can be copied,
/// the website opened. Esc and Backspace go back.
class DetailsPage extends StatelessWidget {
  const DetailsPage({
    super.key,
    required this.core,
    required this.app,
    required this.facts,
    required this.groupName,
    required this.originName,
  });
  final CoreCall core;
  final Map app;
  final Map? facts;
  final String groupName;
  final String? originName;

  static String formatSize(int bytes) {
    const units = ['bytes', 'kB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    return unit == 0 ? '$bytes bytes' : '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  static String formatDate(Object? seconds) {
    if (seconds is! int || seconds <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => '$v'.padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// details_rows: (label, value, copyable).
  List<(String, String, bool)> rows() {
    final f = facts ?? const {};
    const kinds = {
      'app': 'App',
      'webapp': 'Web app',
      'terminal': 'Terminal app',
      'flatpak': 'Flatpak or Snap app',
      'appimage': 'AppImage',
      'cli': 'Command-line tool',
    };
    const roles = {
      'browser': 'Web browser',
      'terminal': 'Terminal',
      'email': 'Email',
      'files': 'Files',
      'editor': 'Text editor',
      'images': 'Images',
      'video': 'Videos',
      'music': 'Music',
      'pdf': 'PDF documents',
    };
    final pkg = f['package'] as Map?;
    final out = <(String, String, bool)>[
      (tr('Type'), kinds[f['kind']] == null ? '' : tr(kinds[f['kind']]!), false),
      (tr('Origin'), originName ?? '', false),
      (
        tr('Default app for'),
        [for (final r in (app['roles'] as List? ?? const [])) if (roles[r] != null) tr(roles[r]!)].join(', '),
        false,
      ),
      (tr('Group'), groupName, false),
      (tr('ID'), '${app['desktop_id'] ?? ''}', false),
      (tr('Desktop file'), '${app['desktop_path'] ?? ''}', true),
      (tr('Command'), '${app['exec'] ?? ''}', false),
      (tr('Program'), '${f['program'] ?? ''}', true),
      if (pkg != null) ...[
        (tr('Package'), '${pkg['name']} ${pkg['version'] ?? ''}'.trim(), false),
        (
          tr('Installed size'),
          pkg['size'] is int ? formatSize(pkg['size'] as int) : '${pkg['size_text'] ?? ''}',
          false,
        ),
        (tr('Installed or updated'), formatDate(pkg['installed']), false),
        (tr('Website'), '${pkg['url'] ?? ''}', true),
      ],
      if (f['website'] != null) (tr('Website'), '${f['website']}', true),
      if (f['file_size'] is int) ...[
        (tr('File size'), formatSize(f['file_size'] as int), false),
        (tr('Last changed'), formatDate(f['modified']), false),
      ],
    ];
    return [for (final r in out) if (r.$2.isNotEmpty) r];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = tr((app['description'] as String? ?? '').trim());
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.backspace)) {
            Navigator.maybePop(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 16, 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [Text('${tr('Back')} · '), const Icon(Icons.backspace_outlined, size: 15)],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    tr('Details').toUpperCase(),
                    style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                children: [
                  Row(
                    children: [
                      AppIcon(app['icon_file'] as String?, size: 48),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${app['name']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            if (description.isNotEmpty)
                              Text(description, style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  for (final (label, value, copyable) in rows())
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 150,
                            child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
                          ),
                          Expanded(child: SelectableText(value)),
                          if (copyable)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: tr('Copy'),
                              icon: const Icon(Icons.copy, size: 16),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: value));
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(SnackBar(content: Text(tr('Copied'))));
                              },
                            ),
                          if (copyable && RegExp(r'^https?://').hasMatch(value))
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: tr('Open in the browser'),
                              icon: const Icon(Icons.open_in_browser, size: 16),
                              onPressed: () => core('open.url', {'url': value}),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
