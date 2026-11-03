import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'install_page.dart';
import 'theme.dart';

/// What the Ask page may do with an installed app: the same flows as the
/// app's own menu (open, uninstall, update, details).
typedef AppActions = ({
  void Function(Map app) open,
  Future<void> Function(Map app) uninstall,
  Future<void> Function(Map app) update,
  Future<void> Function() updateSystem,
  Future<void> Function(Map app) details,
  bool Function(Map app) hasUpdate,
});

/// Ask AI (docs/proposals/ask-ai.md, step 2): one question, one checked
/// proposal; every action goes through the normal reviews. Tokens are spent
/// only when the user clicks Ask (at most two answers per click).
class AskPage extends StatefulWidget {
  const AskPage({super.key, required this.core, required this.apps, required this.actions, this.onOpenInstall});
  final CoreCall core;

  /// The installed apps by key (from apps.list).
  final Map<String, Map<String, dynamic>> apps;
  final AppActions actions;
  final VoidCallback? onOpenInstall;
  @override
  State<AskPage> createState() => _AskPageState();
}

class _AskPageState extends State<AskPage> {
  final request = TextEditingController();
  List<Map<String, dynamic>> helpers = [];
  String? helper;
  bool asking = false;
  Map<String, dynamic>? result;
  String? error;
  String? lastRequest;

  @override
  void initState() {
    super.initState();
    _loadHelpers();
  }

  @override
  void dispose() {
    request.dispose();
    super.dispose();
  }

  Future<void> _loadHelpers() async {
    final r = await widget.core('ask.helpers');
    if (!mounted) return;
    setState(() {
      helpers = [for (final h in r['helpers'] as List) Map<String, dynamic>.from(h)];
      final usable = helpers.where((h) => h['installed'] == true).toList();
      final chosen = r['chosen'] as String?;
      helper = usable.any((h) => h['command'] == chosen)
          ? chosen
          : (usable.where((h) => h['signed_in'] == true).firstOrNull ?? usable.firstOrNull)?['command'] as String?;
    });
  }

  Map<String, dynamic>? get chosen => helpers.where((h) => h['command'] == helper).firstOrNull;

  Future<void> _ask({String? answer}) async {
    final text = answer == null ? request.text.trim() : (lastRequest ?? '');
    if (text.isEmpty || helper == null || asking) return;
    setState(() {
      asking = true;
      error = null;
      if (answer == null) result = null;
      lastRequest = text;
    });
    try {
      final r = await widget.core('ask.run', {
        'request': text,
        'helper': helper,
        'language': I18n.language,
        'answer': ?answer,
      });
      if (mounted) setState(() => result = r);
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() => error = e.code == 'helper_failed' ? tr('The helper did not answer.') : trf('That did not work ({0}).', [e.code]));
      }
    } finally {
      if (mounted) setState(() => asking = false);
    }
  }

  Future<void> _stop() => widget.core('ask.cancel');

  Widget _header(ColorScheme scheme) => Padding(
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
          tr('ASK AI'),
          style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
        ),
      ],
    ),
  );

  /// No helper yet: how to get one, in plain words; searching works without.
  Widget _onboarding(ColorScheme scheme) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        tr('To get app suggestions from an AI, connect an AI helper:'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      for (final h in helpers)
        Card(
          child: ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text('${h['name']}'),
            subtitle: Text(
              h['installed'] != true
                  ? tr('Not installed')
                  : h['signed_in'] == true
                  ? tr('Ready')
                  : tr('Installed — needs sign-in'),
            ),
            trailing: h['installed'] == true && h['signed_in'] != true
                ? TextButton(
                    onPressed: () => widget.core('ask.signin', {'command': h['command']}),
                    child: Text(tr('Sign in in terminal')),
                  )
                : null,
          ),
        ),
      const SizedBox(height: 16),
      Text(tr('Without AI, Install apps searches the packages by name.')),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: widget.onOpenInstall,
          icon: const Icon(Icons.add_box_outlined),
          label: Text(tr('Install apps')),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = helpers.any((h) => h['installed'] == true);
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
            _header(scheme),
            if (helpers.isNotEmpty && !ready) Expanded(child: _onboarding(scheme)),
            if (ready) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Text(tr('Helper:')),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: helper,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final h in helpers.where((h) => h['installed'] == true))
                          DropdownMenuItem(
                            value: h['command'] as String,
                            child: Text(
                              '${h['name']}${h['signed_in'] == true ? '' : ' (${tr('needs sign-in')})'}',
                            ),
                          ),
                      ],
                      onChanged: asking ? null : (v) => setState(() => helper = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        trf('Uses your {0} plan or tokens, only when you click Ask.', [chosen?['name'] ?? '']),
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: TextField(
                  controller: request,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    hintText: tr('What do you need? e.g. “something to edit photos”'),
                    counterText: '',
                    suffixIcon: asking
                        ? IconButton(tooltip: tr('Stop'), onPressed: _stop, icon: const Icon(Icons.stop_circle_outlined))
                        : IconButton(tooltip: tr('Ask'), onPressed: () => _ask(), icon: const Icon(Icons.send)),
                  ),
                  onSubmitted: (_) => _ask(),
                ),
              ),
              if (result == null && !asking)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final starter in [
                        tr('Suggest a photo editor'),
                        tr('Find an app to cut videos'),
                        tr('Which installed app opens PDFs?'),
                        tr('What can I update?'),
                      ])
                        ActionChip(
                          label: Text(starter),
                          onPressed: () {
                            request.text = starter;
                            _ask();
                          },
                        ),
                    ],
                  ),
                ),
              if (asking) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!, style: TextStyle(color: scheme.error)),
                ),
              Expanded(child: result == null ? const SizedBox.shrink() : _result(scheme, result!)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _appRow(Map app, List<Widget> buttons) => ListTile(
    leading: AppIcon(app['icon_file'] as String?, size: 32),
    title: Text('${app['name']}'),
    subtitle: Text(tr(app['description'] as String? ?? ''), maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: Wrap(spacing: 4, children: buttons),
  );

  Widget _result(ColorScheme scheme, Map<String, dynamic> r) {
    final a = widget.actions;
    final apps = [for (final k in (r['apps'] as List? ?? const [])) ?widget.apps[k]];
    final installed = [for (final k in (r['installed'] as List? ?? const [])) ?widget.apps[k]];
    final children = <Widget>[];
    switch (r['action']) {
      case 'install':
        final picks = [for (final x in r['picks'] as List? ?? const []) Map<String, dynamic>.from(x)];
        if ('${r['summary'] ?? ''}'.isNotEmpty) children.add(Text('${r['summary']}'));
        if (installed.isNotEmpty) {
          children.add(_section(tr('Already installed')));
          for (final app in installed) {
            children.add(_appRow(app, [TextButton(onPressed: () => a.open(app), child: Text(tr('Open')))]));
          }
        }
        if (picks.isEmpty && installed.isEmpty) {
          children.add(Text(trf('Nothing found for “{0}”.', [(r['queries'] as List? ?? const []).join(', ')])));
        }
        if (picks.isNotEmpty) children.add(_section(tr('Suggestions')));
        for (final pick in picks) {
          final aur = pick['aur'] == true;
          children.add(
            Card(
              child: ListTile(
                title: Text('${pick['package']}  ${pick['version'] ?? ''}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ('${pick['reason'] ?? ''}'.isNotEmpty) Text('${pick['reason']}'),
                    Text(
                      '${pick['description'] ?? ''}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                leading: Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(aur ? 'AUR' : '${pick['manager']}', style: const TextStyle(fontSize: 11)),
                  backgroundColor: aur ? markColors(context).update.withValues(alpha: .2) : null,
                ),
                trailing: pick['installed'] == true
                    ? Icon(Icons.check_circle, color: markColors(context).running)
                    : TextButton(
                        onPressed: () => reviewInstall(context, widget.core, pick, aur ? 'AUR' : '${pick['manager']}'),
                        child: Text(tr('Install…')),
                      ),
              ),
            ),
          );
        }
      case 'remove':
        children.add(_section(tr('Uninstall')));
        for (final app in apps) {
          children.add(_appRow(app, [TextButton(onPressed: () => a.uninstall(app), child: Text(tr('Uninstall…')))]));
        }
      case 'update':
        children.add(_section(tr('Update')));
        for (final app in apps) {
          children.add(
            _appRow(app, [
              a.hasUpdate(app)
                  ? TextButton(onPressed: () => a.update(app), child: Text(tr('Update')))
                  : Text(tr('No update known'), style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
          );
        }
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: a.updateSystem, child: Text(tr('Update system…'))),
          ),
        );
      case 'update_system':
        children.add(Text(tr('Updates the whole system in a terminal (on Arch never one package alone).')));
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(onPressed: a.updateSystem, child: Text(tr('Update system…'))),
          ),
        );
      case 'explain':
        if ('${r['answer'] ?? ''}'.isNotEmpty) children.add(SelectableText('${r['answer']}'));
        for (final app in apps) {
          children.add(
            _appRow(app, [
              TextButton(onPressed: () => a.open(app), child: Text(tr('Open'))),
              TextButton(onPressed: () => a.details(app), child: Text(tr('Details…'))),
            ]),
          );
        }
      case 'clarify':
        children.add(Text('${r['question']}', style: const TextStyle(fontWeight: FontWeight.w600)));
        children.add(const SizedBox(height: 8));
        children.add(
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final choice in (r['choices'] as List? ?? const []))
                ActionChip(label: Text('$choice'), onPressed: () => _ask(answer: '$choice')),
            ],
          ),
        );
        children.add(
          Text(tr('Choosing asks the helper once more.'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        );
      default:
        final hint = '${r['hint'] ?? ''}';
        children.add(
          Text(hint.isNotEmpty ? hint : tr('Maprisma Launcher can find, install, update, remove and explain apps.')),
        );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c)],
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}
