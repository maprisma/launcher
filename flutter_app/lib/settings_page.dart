import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'theme.dart' show corners;
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

  /// The dock (Omarchy only): dock.state.
  Map<String, dynamic>? dock;

  @override
  void initState() {
    super.initState();
    _loadManagers();
    widget.core('admin.state').then((r) {
      if (mounted) setState(() => admin = r);
    }).ignore();
    widget.core('dock.state').then((r) {
      if (mounted) setState(() => dock = r);
    }).ignore();
  }

  /// A dock setting; switched on, the dock starts (a running one re-reads).
  Future<void> _setDock(String key, Object? value) async {
    try {
      final fresh = await widget.core('dock.set', {'key': key, 'value': value});
      if (mounted) setState(() => dock = fresh);
      if (key == 'dock_enabled' && value == true) await widget.core('dock.start');
    } on ServiceError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Could not save the setting'))));
      }
    }
  }

  Future<void> _resetDock() async {
    try {
      final fresh = await widget.core('dock.reset');
      if (mounted) setState(() => dock = fresh);
    } on ServiceError {
      // Nothing changed.
    }
  }

  /// The DOCK group (build_dock_settings): on/off, edge, auto-hide, length,
  /// corners, sizes, the running marks. Elsewhere: why there is none.
  List<Widget> _dockRows() {
    final state = dock;
    if (state == null) return const [];
    if (state['available'] != true) {
      final why = state['reason'] == 'no_layer_shell'
          ? tr('The dock needs the gtk-layer-shell package (sudo pacman -S gtk-layer-shell).')
          : tr('The dock is only for Omarchy (Hyprland). GNOME and COSMIC have docks of their own.');
      return [
        _row(tr('Show dock'), why, Text(tr('Not available'), key: const ValueKey('dock-unavailable'))),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(why, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ];
    }
    final d = Map<String, dynamic>.from(state['settings'] as Map);
    final bar = state['bar'], edge = '${state['edge']}';
    final names = {'bottom': tr('Bottom'), 'top': tr('Top'), 'left': tr('Left'), 'right': tr('Right')};
    final ends = edge == 'left' || edge == 'right' ? (tr('Top'), tr('Bottom')) : (tr('Left'), tr('Right'));
    Widget toggle(String key, String label, String tip) =>
        _row(label, tip, Switch(key: ValueKey(key), value: d[key] == true, onChanged: (v) => _setDock(key, v)));
    Widget choice(String key, String label, String tip, List<(Object, String)> values) => _row(
      label,
      tip,
      _dropdown<Object>(
        values.any((v) => v.$1 == d[key]) ? d[key] as Object : values.first.$1,
        values,
        (v) => _setDock(key, v),
      ),
    );
    List<(Object, String)> px(List<int> values) => [for (final v in values) (v, '$v px')];
    return [
      toggle(
        'dock_enabled',
        tr('Show dock'),
        tr(
          'A dock with your pinned apps and the running ones along a screen edge. Pin apps with “Pin to dock” in their menu.',
        ),
      ),
      choice(
        'dock_position',
        tr('Position'),
        tr("The screen edge the dock sits on. The bar's edge is left out: the dock never covers the bar."),
        [
          for (final p in const ['bottom', 'top', 'left', 'right'])
            if (p != bar) (p, names[p]!),
        ],
      ),
      toggle(
        'dock_autohide',
        tr('Auto-hide'),
        tr(
          'Hidden until the pointer touches the screen edge. Off: the dock keeps its space and windows stay clear of it.',
        ),
      ),
      toggle('dock_full_width', tr('Full length'), tr('Along the whole screen edge; off: only as long as its icons.')),
      toggle('dock_rounded', tr('Rounded corners'), tr('Round corners, like the windows.')),
      toggle(
        'dock_transparent',
        tr('Transparent'),
        tr("No background, only the icons. Double-click the dock's background to switch, as on the bar."),
      ),
      choice(
        'dock_align',
        tr('Icons'),
        tr('Where the icons sit in a full-length dock. A compact dock is always centred.'),
        [('start', ends.$1), ('center', tr('Center')), ('end', ends.$2)],
      ),
      choice(
        'dock_height',
        tr('Dock height'),
        tr("How high the dock's background is."),
        px(const [32, 40, 48, 56, 64, 72, 80, 96]),
      ),
      choice(
        'dock_icon_size',
        tr('Icon size'),
        tr('Icons larger than the dock stick out of it, as on macOS.'),
        px(const [24, 32, 40, 48, 56, 64, 72, 80, 96]),
      ),
      choice(
        'dock_spacing',
        tr('Icon spacing'),
        tr('The gap between two icons in the dock.'),
        px(const [0, 2, 4, 6, 8, 12, 16]),
      ),
      choice(
        'dock_magnify',
        tr('Grow on hover'),
        tr('The icon under the pointer grows, its neighbours halfway, as on macOS.'),
        [
          (100, tr('Off')),
          for (final v in const [125, 150, 175, 200]) (v, '$v %'),
        ],
      ),
      toggle(
        'dock_bounce',
        tr('Bounce on alerts'),
        tr('An app that wants attention bounces in the dock until you switch to it.'),
      ),
      toggle(
        'dock_indicator_shown',
        tr('Show indicator'),
        tr('Mark running apps in the dock (style and colour below).'),
      ),
      choice(
        'dock_indicator',
        tr('Indicator'),
        tr("How running apps are marked: a dot or a line next to the icon. The focused app's mark is larger."),
        [('dot', tr('Dot')), ('line', tr('Line'))],
      ),
      choice(
        'dock_indicator_color',
        tr('Indicator colour'),
        tr("The colour of the running marks; Theme uses the theme's accent colour."),
        [
          ('theme', tr('Theme')),
          ('foreground', tr('Light')),
          ('red', tr('Red')),
          ('yellow', tr('Yellow')),
          ('green', tr('Green')),
          ('orange', tr('Orange')),
        ],
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          key: const ValueKey('dock-reset'),
          onPressed: _resetDock,
          child: Text(tr('Reset to defaults')),
        ),
      ),
    ];
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

  /// Label left, control right: the control column grows with the room,
  /// 260 px in a small window up to 440 px in a wide one.
  Widget _row(String label, String tip, Widget control) => _Row(
    label,
    tip,
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // The name, and under it what it does (as in the settings of
              // other apps); the explanation is the tooltip too.
              child: Tooltip(
                message: tip,
                waitDuration: const Duration(milliseconds: 400),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    if (tip.isNotEmpty && tip != label)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 2),
                        child: Text(
                          tip,
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: math.min(440.0, math.max(math.min(260.0, box.maxWidth * .55), box.maxWidth - 360)),
              child: Align(alignment: Alignment.centerRight, child: control),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _dropdown<T>(T value, List<(T, String)> choices, ValueChanged<T> onChanged) => DropdownButton<T>(
    value: value,
    isExpanded: true,
    isDense: true,
    underline: const SizedBox.shrink(),
    borderRadius: BorderRadius.circular(8),
    items: [for (final (v, label) in choices) DropdownMenuItem(value: v, child: Text(label))],
    onChanged: (v) => v == null ? null : onChanged(v),
  );

  /// The section chosen last, kept while the app runs.
  static String? _chosen;
  final _find = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _find.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The rows by section (a _Section starts one; _ColumnBreak is ignored).
  List<(_Section, List<Widget>)> _bySection(List<Widget> rows) {
    final out = <(_Section, List<Widget>)>[];
    for (final w in rows) {
      if (w is _Section) {
        out.add((w, []));
      } else if (w is! _ColumnBreak && out.isNotEmpty) {
        out.last.$2.add(w);
      }
    }
    return [
      for (final e in out)
        if (e.$2.isNotEmpty) e,
    ];
  }

  /// Settings as sections on the left and the chosen one's rows on the right,
  /// with Find in Settings above them: a search shows the rows of every
  /// section whose name or explanation says what was typed.
  Widget _pages(List<Widget> rows) {
    final scheme = Theme.of(context).colorScheme;
    final sections = _bySection(rows);
    final query = _find.text.trim().toLowerCase();
    final currentId = sections.any((e) => e.$1.id == _chosen) ? _chosen! : sections.first.$1.id;
    final current = sections.firstWhere((e) => e.$1.id == currentId).$1.title;
    bool hit(Widget w) => w is _Row && (w.label.toLowerCase().contains(query) || w.tip.toLowerCase().contains(query));
    final shown = query.isEmpty
        ? [
            for (final e in sections)
              if (e.$1.id == currentId) e,
          ]
        : [
            for (final e in sections)
              if (e.$1.title.toLowerCase().contains(query))
                e
              else if (e.$2.any(hit))
                (
                  e.$1,
                  [
                    for (final w in e.$2)
                      if (hit(w)) w,
                  ],
                ),
          ];
    void choose(String id) {
      setState(() {
        _chosen = id;
        _find.clear();
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }

    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(corners(context).clamp(6, 16)));
    Widget find(double side) => Padding(
      padding: EdgeInsets.fromLTRB(side, 4, side, 8),
      child: Align(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: TextField(
            key: const ValueKey('settings-find'),
            controller: _find,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: tr('Find in Settings'),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: tr('Clear'),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(_find.clear),
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ),
    );
    Widget content(double side, {bool reset = false}) => KeyedSubtree(
      key: const ValueKey('settings-content'),
      child: ListView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(side, 4, side, 24),
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    query.isEmpty ? current : tr('Find in Settings'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  if (shown.isEmpty) Text(tr('No setting matches “{0}”').replaceAll('{0}', _find.text.trim())),
                  for (final (section, members) in shown) ...[
                    if (query.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(section.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ...members,
                    const SizedBox(height: 28),
                  ],
                  // Narrow: no list on the left, so Reset is under the rows.
                  if (reset)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('settings-reset'),
                        onPressed: _reset,
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: Text(tr('Reset to defaults'), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        // A narrow window (the popup): the sections as chips above the rows.
        if (box.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              find(16),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final (section, _) in sections)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          key: ValueKey('settings-section-${section.id}'),
                          avatar: Icon(section.icon, size: 16),
                          label: Text(section.title),
                          selected: query.isEmpty && section.id == currentId,
                          onSelected: (_) => choose(section.id),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: content(16, reset: true)),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 230,
              // A Material, so the chosen section's highlight shows on it.
              child: Material(
                color: scheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 48, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (section, _) in sections)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: ListTile(
                            key: ValueKey('settings-section-${section.id}'),
                            leading: Icon(section.icon, size: 20),
                            title: Text(section.title, overflow: TextOverflow.ellipsis),
                            selected: query.isEmpty && section.id == currentId,
                            selectedTileColor: scheme.secondaryContainer,
                            selectedColor: scheme.onSecondaryContainer,
                            shape: rounded,
                            onTap: () => choose(section.id),
                          ),
                        ),
                      const Spacer(),
                      ListTile(
                        key: const ValueKey('settings-reset'),
                        leading: const Icon(Icons.restart_alt, size: 20),
                        title: Text(tr('Reset to defaults'), overflow: TextOverflow.ellipsis),
                        shape: rounded,
                        onTap: _reset,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  find(28),
                  Expanded(child: content(28)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sizes = Map<String, dynamic>.from(settings['icon_sizes'] as Map? ?? const {});
    final shown = List<String>.from(settings['shown_layouts'] as List? ?? const ['folders', 'cards', 'icons']);
    final layouts = [('folders', tr('Folders')), ('cards', tr('Cards')), ('icons', tr('Icons')), ('cube', tr('Cube'))];
    final rounding = widget.windowRounding;
    // Compact: no 48 px tap targets around switches, chips and dropdowns.
    return Theme(
      data: Theme.of(context)
          .copyWith(visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: Scaffold(
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 16, 4),
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
                    Flexible(
                      child: Text(
                        tr('SETTINGS'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _pages([
                  _Section('general', tr('General'), Icons.tune),
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
                    tr(
                      'A popup floats in the middle of the screen and closes with Esc or a click elsewhere, like the old App Manager; a normal window stays and is placed by the desktop. Auto: a popup on Omarchy, a window elsewhere.',
                    ),
                    _dropdown<String>(settings['window_mode'] as String? ?? 'auto', [
                      ('auto', tr('Auto')),
                      ('popup', tr('Popup')),
                      ('window', tr('Normal window')),
                    ], (v) => _set('window_mode', v)),
                  ),
                  _row(
                    tr('Close on click outside'),
                    tr('In popup mode, clicking outside the window hides it.'),
                    Switch(
                      key: const ValueKey('close-outside'),
                      value: settings['close_outside'] != false,
                      onChanged: (v) => _set('close_outside', v),
                    ),
                  ),
                  _Section('layout', tr('Layout'), Icons.dashboard_outlined),
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
                    Switch(
                      key: const ValueKey('view-buttons'),
                      value: settings['view_buttons'] == true,
                      onChanged: (v) => _set('view_buttons', v),
                    ),
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
                    tr('Layouts in the header'),
                    tr(
                      'Which layouts the view buttons in the header offer, left of the other buttons. At least one stays on; with only one, they are hidden.',
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
                  _Section('sizes', tr('Icon sizes'), Icons.photo_size_select_large_outlined),
                  for (final (view, label, tip) in [
                    ('list', tr('List'), tr("How large the app icons are in the narrow window's list.")),
                    ('cards', tr('Cards'), tr('How large the app icons are on the cards; the cards grow with them.')),
                    (
                      'folders',
                      tr('Folders'),
                      tr(
                        'How much of its room in a folder each icon fills. 100 % fills the page; smaller shrinks the icons.',
                      ),
                    ),
                    (
                      'icons',
                      tr('Icons'),
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
                  // The second column (wide window) starts here.
                  const _ColumnBreak(),
                  _Section('apps', tr('Apps & AI'), Icons.auto_awesome_outlined),
                  _row(
                    tr('Ask AI'),
                    tr('Without AI, Install apps searches the packages by name.'),
                    Switch(
                      key: const ValueKey('ai-enabled'),
                      value: settings['ai_enabled'] != false,
                      onChanged: (v) => _set('ai_enabled', v),
                    ),
                  ),
                  if (managers.isNotEmpty)
                    _row(
                      tr('Package managers'),
                      tr(
                        'Which package managers Install apps (and later Ask AI) may use. The AUR is off until you choose it: community build scripts, not checked by the distribution.',
                      ),
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
                      tr(
                        "Adds “Open as administrator” to an app's menu. Switching it on asks for your password; it is off again after you log in next time.",
                      ),
                      Switch(value: admin['enabled'] == true, onChanged: adminPending ? null : _setAdmin),
                    ),
                  _Section('screenshots', tr('Screenshots'), Icons.photo_camera_outlined),
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
                  _Section('dock', tr('Dock'), Icons.dock_outlined),
                  ..._dockRows(),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the settings' second column begins (only a marker, never drawn).
class _ColumnBreak extends StatelessWidget {
  const _ColumnBreak();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Where a settings group card begins (only a marker, never drawn).
class _Section extends StatelessWidget {
  const _Section(this.id, this.title, this.icon);

  /// Stable, whatever the language: the key `settings-section-$id`.
  final String id;
  final String title;
  final IconData icon;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// A settings row: its name and explanation (Find in Settings searches them)
/// and how it is drawn.
class _Row extends StatelessWidget {
  const _Row(this.label, this.tip, this.child);
  final String label, tip;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
