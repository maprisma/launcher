import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'theme.dart';

/// Install apps (Ask AI step 1, no AI): search the package managers the user
/// allows, then a review with the exact command before a terminal runs it.
class InstallPage extends StatefulWidget {
  const InstallPage({super.key, required this.core, this.onInstalled});
  final CoreCall core;
  final VoidCallback? onInstalled;
  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final query = TextEditingController();
  List<Map<String, dynamic>> managers = [];
  List<Map<String, dynamic>> results = [];
  bool searching = false;
  String? searched;

  @override
  void initState() {
    super.initState();
    widget.core('packages.managers').then((r) {
      if (mounted) setState(() => managers = [for (final m in r['managers'] as List) Map<String, dynamic>.from(m)]);
    });
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final text = query.text.trim();
    if (text.isEmpty) return;
    setState(() => searching = true);
    try {
      final r = await widget.core('packages.search', {'query': text});
      if (!mounted) return;
      setState(() {
        results = [for (final f in r['results'] as List) Map<String, dynamic>.from(f)];
        searched = text;
      });
    } on ServiceError catch (e) {
      _tell(trf('That did not work ({0}).', [e.code]));
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  String _managerLabel(String id) =>
      managers.where((m) => m['id'] == id).firstOrNull?['label'] as String? ?? id;

  Future<void> _review(Map found) async {
    Map<String, dynamic> plan;
    try {
      plan = await widget.core('packages.install_plan', {'manager': found['manager'], 'package': found['package']});
    } on ServiceError catch (e) {
      _tell(trf('That did not work ({0}).', [e.code]));
      return;
    }
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('Install {0}?', [found['name'] ?? found['package']])),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((found['description'] as String? ?? '').isNotEmpty) Text('${found['description']}'),
            const SizedBox(height: 12),
            Text(trf('From: {0}', [_managerLabel('${found['manager']}')])),
            const SizedBox(height: 8),
            Text(tr('A terminal runs this and asks for your password:')),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
              child: SelectableText('${plan['command']}', style: const TextStyle(fontFamily: 'monospace')),
            ),
            if (plan['aur'] == true) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: markColors(context).update.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  tr(
                    'Community package from the Arch User Repository (AUR). Anyone can upload AUR build scripts: read the PKGBUILD the helper shows before you build.',
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Install in terminal'))),
        ],
      ),
    );
    if (go != true) return;
    try {
      await widget.core('packages.install', {'manager': found['manager'], 'package': found['package']});
      widget.onInstalled?.call();
    } on ServiceError {
      _tell(tr('No terminal found.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = managers.where((m) => m['enabled'] == true).map((m) => m['label']).join(', ');
    return Scaffold(
      body: Focus(
        autofocus: true,
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
              padding: const EdgeInsets.fromLTRB(8, 10, 16, 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: Text(tr('Back')),
                  ),
                  const Spacer(),
                  Text(
                    tr('INSTALL APPS'),
                    style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                controller: query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: tr('Package name or word, e.g. gimp'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  enabled.isEmpty
                      ? tr('No package manager is enabled (Settings › Package managers).')
                      : trf('Searches: {0}', [enabled]),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            Expanded(
              child: searched != null && results.isEmpty && !searching
                  ? Center(child: Text(trf('Nothing found for “{0}”.', [searched])))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: results.length,
                      itemBuilder: (context, i) {
                        final f = results[i];
                        final aur = f['aur'] == true;
                        return ListTile(
                          title: Text(
                            '${f['name'] ?? f['package']}  ${f['version'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${f['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                          leading: Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(_managerLabel('${f['manager']}'), style: const TextStyle(fontSize: 11)),
                            backgroundColor: aur ? markColors(context).update.withValues(alpha: .2) : null,
                          ),
                          trailing: f['installed'] == true
                              ? Tooltip(
                                  message: tr('Installed'),
                                  child: Icon(Icons.check_circle, color: markColors(context).running),
                                )
                              : TextButton(onPressed: () => _review(f), child: Text(tr('Install…'))),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
