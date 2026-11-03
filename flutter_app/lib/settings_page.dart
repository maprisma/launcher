import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'main.dart' show PopupGuard;

/// launcher_core's choices per setting.
const iconSizeChoices = {
  'list': [20, 24, 28, 32, 36, 44, 52],
  'cards': [32, 40, 44, 48, 56, 64],
  'folders': [50, 60, 70, 80, 90, 100],
  'icons': [48, 56, 64, 72, 88, 96, 112, 128],
};

/// Settings (build_settings_page): label | control rows, each with its
/// tooltip; "← Back · ⌫" and Esc go back; Reset to defaults bottom left.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.core,
    required this.settings,
    required this.onChanged,
    this.windowRounding,
  });
  final CoreCall core;
  final Map<String, dynamic> settings;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final int? windowRounding;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Map<String, dynamic> settings = widget.settings;
  List<Map<String, dynamic>> managers = [];
  Map<String, dynamic> admin = const {};
  bool adminPending = false;

  @override
  void initState() {
    super.initState();
    _loadManagers();
    widget.core('admin.state').then((r) {
      if (mounted) setState(() => admin = r);
    }).ignore();
  }

  /// on_admin_action_toggled: on only after polkit confirmed the password.
  Future<void> _setAdmin(bool on) async {
    setState(() => adminPending = true);
    try {
      // The polkit dialog takes the focus: the popup must not hide meanwhile.
      final r = await PopupGuard.around(() => widget.core('admin.enable', {'on': on}));
      if (mounted) setState(() => admin = {...admin, 'enabled': r['enabled']});
    } on ServiceError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${tr('Open as administrator was not switched on')}: ${e.code == 'not_confirmed' ? tr('The password was not confirmed.') : tr('Not authorized, or no polkit agent is running.')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => adminPending = false);
    }
  }

  Future<void> _loadManagers() async {
    try {
      final r = await widget.core('packages.managers');
      if (mounted) setState(() => managers = [for (final m in r['managers'] as List) Map<String, dynamic>.from(m)]);
    } on ServiceError {
      // No row then.
    }
  }

  Future<void> _set(String key, Object? value) async {
    try {
      final fresh = await widget.core('settings.set', {'key': key, 'value': value});
      setState(() => settings = fresh);
      widget.onChanged(fresh);
    } on ServiceError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Could not save the setting'))));
      }
    }
  }

  Future<void> _reset() async {
    final fresh = await widget.core('settings.reset');
    setState(() => settings = fresh);
    widget.onChanged(fresh);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.backspace &&
                FocusManager.instance.primaryFocus is! EditableTextState)) {
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _row(String label, String tip, Widget control) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Tooltip(message: tip, waitDuration: const Duration(milliseconds: 400), child: Text(label)),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 260,
          child: Align(alignment: Alignment.centerRight, child: control),
        ),
      ],
    ),
  );

  Widget _dropdown<T>(T value, List<(T, String)> choices, ValueChanged<T> onChanged) => DropdownButton<T>(
    value: value,
    isExpanded: true,
    underline: const SizedBox.shrink(),
    borderRadius: BorderRadius.circular(8),
    items: [for (final (v, label) in choices) DropdownMenuItem(value: v, child: Text(label))],
    onChanged: (v) => v == null ? null : onChanged(v),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sizes = Map<String, dynamic>.from(settings['icon_sizes'] as Map? ?? const {});
    final shown = List<String>.from(settings['shown_layouts'] as List? ?? const ['folders', 'cards', 'icons']);
    final layouts = [('folders', tr('Folders')), ('cards', tr('Cards')), ('icons', tr('Icons'))];
    final rounding = widget.windowRounding;
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
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
                    tr('SETTINGS'),
                    style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                children: [
                  _row(
                    tr('Language'),
                    tr('The interface language. “System” follows the language of your desktop.'),
                    _dropdown<String>(settings['language'] as String? ?? 'auto', [
                      ('auto', tr('System')),
                      for (final (code, name) in languages) (code, name),
                    ], (v) => _set('language', v)),
                  ),
                  _row(
                    tr('Window'),
                    tr('A popup floats in the middle of the screen and closes with Esc or a click elsewhere, like the old App Manager; a normal window stays and is placed by the desktop. Auto: a popup on Omarchy, a window elsewhere.'),
                    _dropdown<String>(settings['window_mode'] as String? ?? 'auto', [
                      ('auto', tr('Auto')),
                      ('popup', tr('Popup')),
                      ('window', tr('Normal window')),
                    ], (v) => _set('window_mode', v)),
                  ),
                  _row(
                    tr('Layout when small'),
                    tr('How the narrow window shows the entries: as one list (the default), in groups, or by origin.'),
                    _dropdown<String>(settings['view'] as String? ?? 'list', [
                      ('list', tr('List')),
                      ('groups', tr('Groups')),
                      ('origin', tr('By origin')),
                    ], (v) => _set('view', v)),
                  ),
                  _row(
                    tr('Layout when wide'),
                    tr(
                      'How the window shows the entries once it is two columns wide or more: each group as a folder of icons (the default), every entry as a card, or every entry as a large icon.',
                    ),
                    _dropdown<String>(
                      settings['wide_layout'] as String? ?? 'folders',
                      layouts,
                      (v) => _set('wide_layout', v),
                    ),
                  ),
                  _row(
                    tr('View buttons when small'),
                    tr(
                      "Buttons in the narrow window's header to switch between groups, list and origin (Ctrl+G does the same).",
                    ),
                    Switch(value: settings['view_buttons'] == true, onChanged: (v) => _set('view_buttons', v)),
                  ),
                  _row(
                    tr('Corners'),
                    tr(
                      'Corners of the window, its folders and cards. “Like windows” follows the desktop\'s rounded corners.',
                    ),
                    _dropdown<String>(settings['corners'] as String? ?? 'windows', [
                      ('windows', rounding == null ? tr('Like windows') : trf('Like windows ({0} px)', [rounding])),
                      ('rounded', tr('Rounded')),
                      ('square', tr('Square')),
                    ], (v) => _set('corners', v)),
                  ),
                  _row(
                    tr('Layouts in the footer'),
                    tr(
                      'Which layouts the buttons at the right end of the footer offer. At least one stays on; with only one, the buttons are hidden.',
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final (id, name) in layouts)
                          FilterChip(
                            label: Text(name),
                            selected: shown.contains(id),
                            onSelected: (on) {
                              final next = [
                                for (final (l, _) in layouts)
                                  if (l == id ? on : shown.contains(l)) l,
                              ];
                              // Never none: the last one stays on.
                              if (next.isNotEmpty) _set('shown_layouts', next);
                            },
                          ),
                      ],
                    ),
                  ),
                  _row(
                    tr('Filter field'),
                    tr(
                      'The field above the folders when wide. Without it, typing still filters and the title shows what you typed.',
                    ),
                    Switch(value: settings['filter_field'] != false, onChanged: (v) => _set('filter_field', v)),
                  ),
                  if (managers.isNotEmpty)
                    _row(
                      tr('Package managers'),
                      tr('Which package managers Install apps (and later Ask AI) may use. The AUR is off until you choose it: community build scripts, not checked by the distribution.'),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        alignment: WrapAlignment.end,
                        children: [
                          for (final m in managers)
                            FilterChip(
                              label: Text(m['id'] == 'aur' ? 'AUR (${m['program']})' : '${m['label']}'),
                              selected: m['enabled'] == true,
                              onSelected: (on) async {
                                final next = [
                                  for (final x in managers)
                                    if (x['id'] == m['id'] ? on : x['enabled'] == true) x['id'],
                                ];
                                await _set('package_managers', next);
                                await _loadManagers();
                              },
                            ),
                        ],
                      ),
                    ),
                  if (admin['available'] == true)
                    _row(
                      tr('Open as administrator'),
                      tr("Adds “Open as administrator” to an app's menu. Switching it on asks for your password; it is off again after you log in next time."),
                      Switch(
                        value: admin['enabled'] == true,
                        onChanged: adminPending ? null : _setAdmin,
                      ),
                    ),
                  _row(
                    tr('F12 saves a screenshot'),
                    tr('A picture of this window is saved, with a note if you like.'),
                    Switch(
                      key: const ValueKey('screenshot-key'),
                      value: settings['screenshot_key'] != false,
                      onChanged: (v) => _set('screenshot_key', v),
                    ),
                  ),
                  _row(
                    tr('Screenshots go to'),
                    settings['screenshot_folder'] as String? ?? '~/Pictures/MaprismaLauncher',
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Flexible(
                          child: Text(
                            settings['screenshot_folder'] as String? ?? '~/Pictures/MaprismaLauncher',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                        if (settings['screenshot_folder'] != null)
                          TextButton(onPressed: () => _set('screenshot_folder', null), child: Text(tr('Default'))),
                        IconButton(
                          key: const ValueKey('screenshot-folder'),
                          tooltip: tr('Choose folder…'),
                          icon: const Icon(Icons.folder_open),
                          onPressed: () async {
                            final chosen = await PopupGuard.around(getDirectoryPath);
                            if (chosen != null) await _set('screenshot_folder', chosen);
                          },
                        ),
                      ],
                    ),
                  ),
                  for (final (view, label, tip) in [
                    ('list', tr('Icon size: List'), tr("How large the app icons are in the narrow window's list.")),
                    (
                      'cards',
                      tr('Icon size: Cards'),
                      tr('How large the app icons are on the cards; the cards grow with them.'),
                    ),
                    (
                      'folders',
                      tr('Icon size: Folders'),
                      tr(
                        'How much of its room in a folder each icon fills. 100 % fills the page; smaller shrinks the icons.',
                      ),
                    ),
                    (
                      'icons',
                      tr('Icon size: Icons'),
                      tr('How large the icons are in the Icons layout; the tiles grow with them.'),
                    ),
                  ])
                    _row(
                      label,
                      tip,
                      _dropdown<int>(sizes[view] as int? ?? iconSizeChoices[view]!.first, [
                        for (final size in iconSizeChoices[view]!) (size, view == 'folders' ? '$size %' : '$size px'),
                      ], (v) => _set('icon_size', {'view': view, 'size': v})),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Flexible(
                    child: OutlinedButton(
                      onPressed: _reset,
                      child: Text(tr('Reset to defaults'), overflow: TextOverflow.ellipsis),
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
