import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'theme.dart';

/// Change icon (launcher.py open_icon_page / search_icons): installed theme
/// icons at once, online candidates as their previews arrive (six at a
/// time); a click uses one. Esc goes back; Backspace edits the search.
class IconPage extends StatefulWidget {
  const IconPage({super.key, required this.core, required this.app, this.foreground});
  final CoreCall core;
  final Map app;

  /// The theme's text colour, for the one-colour Simple Icons.
  final String? foreground;
  @override
  State<IconPage> createState() => _IconPageState();
}

class _IconPageState extends State<IconPage> {
  late final query = TextEditingController(text: '${widget.app['name']}');
  List<Map<String, dynamic>> theme = [];
  final online = <Map<String, dynamic>>[];
  bool searching = false;
  int _search = 0;
  String status = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final text = query.text.trim();
    if (text.isEmpty) return;
    final mine = ++_search;
    setState(() {
      searching = true;
      theme = [];
      online.clear();
      status = tr('Searching…');
    });
    try {
      final r = await widget.core('icons.search', {'key': widget.app['key'], 'query': text});
      if (!mounted || mine != _search) return;
      setState(() => theme = [for (final t in r['theme'] as List) Map<String, dynamic>.from(t)]);
      final candidates = [for (final c in r['online'] as List) Map<String, dynamic>.from(c)];
      // Six downloads at a time; each shows as soon as it is there.
      var next = 0;
      Future<void> worker() async {
        while (next < candidates.length && mine == _search) {
          final c = candidates[next++];
          try {
            final p = await widget.core('icons.preview', {'url': c['url'], 'color': ?widget.foreground});
            if (p['file'] is String && mounted && mine == _search) setState(() => online.add({...c, 'file': p['file']}));
          } on ServiceError {
            // That one is not on the CDN.
          }
        }
      }

      await Future.wait([for (var i = 0; i < 6; i++) worker()]);
      if (!mounted || mine != _search) return;
      setState(
        () => status = theme.isEmpty && online.isEmpty
            ? tr('Nothing found. Try another name, e.g. the company.')
            : tr('Click an icon to use it.'),
      );
    } on ServiceError catch (e) {
      if (mounted) setState(() => status = trf('That did not work ({0}).', [e.code]));
    } finally {
      if (mounted && mine == _search) setState(() => searching = false);
    }
  }

  Future<void> _use(Map<String, dynamic> params) async {
    try {
      await widget.core('icons.set', {'key': widget.app['key'], 'color': ?widget.foreground, ...params});
      if (mounted) Navigator.pop(context, true);
    } on ServiceError catch (e) {
      if (mounted) setState(() => status = trf('That did not work ({0}).', [e.code]));
    }
  }

  Widget _tile(String? file, String caption, VoidCallback onTap) => Tooltip(
    message: caption,
    child: InkWell(
      borderRadius: BorderRadius.circular(cornerSizes(context).control),
      onTap: onTap,
      child: SizedBox(
        width: 96,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              AppIcon(file, size: 48),
              const SizedBox(height: 4),
              Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.maybePop(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: Text(tr('Back')),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      trf('Icon for {0}', [widget.app['name']]),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  AppIcon(widget.app['icon_file'] as String?, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: query,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: tr('Name of the app or its maker'),
                        prefixIcon: const Icon(Icons.search, size: 20),
                      ),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  if (widget.app['icon_chosen'] == true) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        await widget.core('icons.reset', {'key': widget.app['key']});
                        if (context.mounted) Navigator.pop(context, true);
                      },
                      child: Text(tr('Use its own icon')),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  if (searching) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (searching) const SizedBox(width: 8),
                  Text(status, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  if (theme.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                      child: Text(tr('Installed icons'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Wrap(
                      children: [
                        for (final t in theme) _tile(t['file'] as String?, '${t['name']}', () => _use({'name': t['name']})),
                      ],
                    ),
                  ],
                  if (online.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                      child: Text(tr('Online (open icon collections)'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Wrap(
                      children: [
                        for (final c in online)
                          _tile(c['file'] as String?, '${c['slug']} · ${c['collection']}', () => _use({'url': c['url']})),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
