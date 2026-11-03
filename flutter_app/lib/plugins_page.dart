import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'theme.dart';

/// Omarchy's shell plugins (the old App Manager's plugin page): open them,
/// put bar widgets into the bar or take them out, update and remove them,
/// all through Omarchy's own commands.
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, required this.core, this.onHide});
  final CoreCall core;
  final VoidCallback? onHide;
  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  List<Map<String, dynamic>> plugins = [];
  Map<String, dynamic> behind = {};
  bool loading = true;
  String query = '';

  @override
  void initState() {
    super.initState();
    _load();
    _checkUpdates();
  }

  Future<void> _load() async {
    try {
      final r = await widget.core('plugins.list');
      if (!mounted) return;
      setState(() {
        plugins = [for (final x in r['plugins'] as List) Map<String, dynamic>.from(x)];
        loading = false;
      });
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() => loading = false);
        _tell(trf('That did not work ({0}).', [e.code]));
      }
    }
  }

  Future<void> _checkUpdates({bool force = false}) async {
    try {
      final r = await widget.core('plugins.updates', {'force': force});
      if (mounted) setState(() => behind = Map<String, dynamic>.from(r['behind'] as Map));
    } on ServiceError {
      // No marks then.
    }
  }

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _do(String route, Map<String, dynamic> params, {String? done}) async {
    try {
      await widget.core(route, params);
      if (done != null) _tell(done);
      await _load();
    } on ServiceError catch (e) {
      _tell(e.reason ?? trf('That did not work ({0}).', [e.code]));
    }
  }

  Future<void> _open(Map plugin) async {
    if (plugin['openable'] != true) {
      _tell(tr('Put it into the bar first: its panel opens from its bar button.'));
      return;
    }
    widget.onHide?.call();
    await _do('plugins.open', {'plugin_id': plugin['plugin_id']});
  }

  Future<void> _remove(Map plugin) async {
    Map<String, dynamic> note;
    try {
      note = await widget.core('plugins.remove_plan', {'plugin_id': plugin['plugin_id']});
    } on ServiceError {
      return;
    }
    if (!mounted) return;
    final loses = note['loses_work'] == true;
    final lost = [
      if (note['unchecked'] == true) tr('its git state could not be checked'),
      if ((note['changed'] as int? ?? 0) > 0) trn('{0} changed file', '{0} changed files', note['changed'] as int),
      if (note['no_upstream'] == true) tr('commits that exist nowhere else (no upstream)'),
      if ((note['ahead'] as int? ?? 0) > 0) trn('{0} unpushed commit', '{0} unpushed commits', note['ahead'] as int),
    ];
    final text = switch (note['note']) {
      'link' => tr('Only the link is removed; the folder it points to stays.'),
      'backup' => tr('The folder is kept as a backup in ~/.config/omarchy/plugins.'),
      'loses' => trf('The folder is deleted, including {0}.', [lost.join(tr(' and '))]),
      _ => tr('The folder is deleted; it can be installed again from the marketplace.'),
    };
    final scheme = Theme.of(context).colorScheme;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('Do you want to uninstall {0}?', [plugin['name']])),
        content: Text(text, style: TextStyle(color: loses ? scheme.error : null)),
        actions: [
          // Losing work: Enter must not do it by accident.
          TextButton(autofocus: loses, onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(
            autofocus: !loses,
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Uninstall')),
          ),
        ],
      ),
    );
    if (go == true) {
      await _do('plugins.remove', {'plugin_id': plugin['plugin_id']}, done: trf('Uninstalled {0}', [plugin['name']]));
    }
  }

  Future<void> _menu(Map plugin, Offset at) async {
    final inBar = plugin['in_bar'] == true;
    final behindBy = behind[plugin['plugin_id']] as int?;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(value: 'open', enabled: plugin['openable'] == true, child: Text(tr('Open'))),
        if (plugin['bar_widget'] == true) ...[
          const PopupMenuDivider(),
          if (inBar)
            PopupMenuItem(value: 'out', child: Text(tr('Take out of the bar')))
          else ...[
            for (final section in ['left', 'center', 'right'])
              PopupMenuItem(
                value: 'in:$section',
                child: Text(switch (section) {
                  'left' => tr('Put into the bar: left'),
                  'center' => tr('Put into the bar: centre'),
                  _ => tr('Put into the bar: right'),
                }),
              ),
          ],
        ],
        if (behindBy != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(value: 'update', child: Text(tr('Update'))),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(value: 'folder', child: Text(tr('Copy its folder'))),
        if (plugin['removable'] == true) PopupMenuItem(value: 'remove', child: Text(tr('Uninstall…'))),
      ],
    );
    switch (choice) {
      case 'open':
        await _open(plugin);
      case 'out':
        await _do('plugins.bar', {'plugin_id': plugin['plugin_id'], 'placed': false});
      case final String c when c.startsWith('in:'):
        await _do('plugins.bar', {'plugin_id': plugin['plugin_id'], 'placed': true, 'section': c.substring(3)});
      case 'update':
        _tell(trf('Updating {0}…', [plugin['name']]));
        await _do('plugins.update', {'plugin_id': plugin['plugin_id']}, done: trf('{0} updated', [plugin['name']]));
        await _checkUpdates();
      case 'folder':
        await Clipboard.setData(ClipboardData(text: '${plugin['plugin_dir']}'));
        _tell(tr('Copied'));
      case 'remove':
        await _remove(plugin);
    }
  }

  Widget _row(Map plugin) {
    final scheme = Theme.of(context).colorScheme;
    final behindBy = behind[plugin['plugin_id']] as int?;
    final description = '${plugin['description'] ?? ''}';
    return GestureDetector(
      onSecondaryTapDown: (d) => _menu(plugin, d.globalPosition),
      child: ListTile(
        leading: Icon(Icons.extension_outlined, color: plugin['openable'] == true ? scheme.primary : scheme.onSurfaceVariant),
        title: Row(
          children: [
            Flexible(child: Text('${plugin['name']}', overflow: TextOverflow.ellipsis)),
            if ('${plugin['version'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text('${plugin['version']}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
            if (behindBy != null) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: trn('{0} new commit', '{0} new commits', behindBy),
                child: Icon(Icons.arrow_circle_up, size: 16, color: markColors(context).update),
              ),
            ],
          ],
        ),
        subtitle: description.isEmpty ? null : Text(description, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Builder(
          builder: (context) => IconButton(
            tooltip: tr('Plugin actions'),
            icon: const Icon(Icons.more_vert, size: 18),
            onPressed: () {
              final box = context.findRenderObject()! as RenderBox;
              _menu(plugin, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
            },
          ),
        ),
        onTap: () => _open(plugin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = query.toLowerCase().trim();
    final shown = [for (final x in plugins) if ('${x['name']}'.toLowerCase().contains(q)) x];
    final sections = [
      (tr('In the bar'), [for (final x in shown) if (x['in_bar'] == true) x]),
      (tr('Not in the bar'), [for (final x in shown) if (x['bar_widget'] == true && x['in_bar'] != true) x]),
      (tr('Panels and overlays'), [for (final x in shown) if (x['bar_widget'] != true) x]),
    ];
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
                  IconButton(
                    tooltip: tr('Check for updates'),
                    onPressed: () => _checkUpdates(force: true),
                    icon: const Icon(Icons.refresh),
                  ),
                  Text(
                    tr('PLUGINS'),
                    style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: tr('Type to filter'), prefixIcon: const Icon(Icons.search, size: 20)),
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final (title, items) in sections)
                          if (items.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            for (final x in items) _row(x),
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
