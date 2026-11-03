import 'dart:async';

import 'package:appmanager_core/appmanager_core.dart'
    as sizes
    show
        cardPadding,
        defaultIconSizes,
        folderAppIcon,
        folderColumns,
        folderFit,
        folderIconsHeight,
        folderRows,
        folderTileSize,
        gridColumns,
        iconColumns,
        tileSpacing,
        tileTextHeight;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'drag_drop.dart';
import 'i18n.dart';
import 'settings_page.dart';
import 'theme.dart';

part 'overview.dart';

/// The narrow window's views (launcher_core.saved_view).
enum AppView { list, groups, origin }

/// The wide window's layouts (launcher_core.WIDE_LAYOUTS).
enum WideLayout { folders, cards, icons }

const builtinGroupNames = {
  'office': 'Office',
  'internet': 'Internet',
  'media': 'Media',
  'graphics': 'Graphics',
  'development': 'Development',
  'games': 'Games',
  'system': 'System',
  'utilities': 'Utilities',
};
const originNames = {
  'o-defaults': 'Your default apps',
  'o-system': 'System',
  'o-flatpak': 'Flatpak',
  'o-user': 'Your own',
  'o-omarchy': 'Comes with Omarchy',
  'o-other': 'Other',
};

/// One heading or one entry of the narrow list.
sealed class ListItem {}

final class HeadingRow extends ListItem {
  HeadingRow(this.id, this.count, this.collapsed);
  final String id;
  final int count;
  final bool collapsed;
}

final class AppRow extends ListItem {
  AppRow(this.app, [this.section]);
  final Map<String, dynamic> app;

  /// The group or origin section it shows in (none in A–Z).
  final String? section;
}

class AppsPage extends StatefulWidget {
  const AppsPage({
    super.key,
    required this.core,
    required this.desktop,
    this.shownAgain,
    this.onHide,
    this.onSettings,
    this.windowRounding,
  });
  final CoreCall core;
  final String desktop;

  /// The settings changed (corners, language): the app's theme follows.
  final ValueChanged<Map<String, dynamic>>? onSettings;
  final int? windowRounding;
  final Listenable? shownAgain;
  final VoidCallback? onHide;
  @override
  State<AppsPage> createState() => AppsPageState();
}

class AppsPageState extends State<AppsPage> {
  List<Map<String, dynamic>> apps = [];
  final byKey = <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>> groups = [];
  List<String> collapsed = [];

  /// The narrow view's sections (groups or origin), and the groups for the
  /// overview's folders and footer, both for the entries shown.
  List<(String, List<String>)> sections = [];
  List<(String, List<String>)> groupSections = [];
  bool loading = true;
  bool showHidden = false;
  String query = '';
  AppView view = AppView.list;
  WideLayout wideLayout = WideLayout.folders;
  List<WideLayout> shownLayouts = WideLayout.values;
  Map<String, int> iconSizes = {...sizes.defaultIconSizes};
  Map<String, dynamic> settings = const {};
  bool get viewButtons => settings['view_buttons'] == true;
  bool get filterFieldShown => !wide || settings['filter_field'] != false;

  /// The overview's group ("all" or a group id); during a search the one
  /// picked for this search only.
  String overviewFilter = 'all';
  String? searchFilter;
  bool wide = false;
  String? selectedKey;
  int _columns = 1;
  int _asked = 0;
  final filter = TextEditingController();
  final filterFocus = FocusNode();

  /// The page's own focus: it takes the keys when there is no filter field.
  final pageFocus = FocusNode(debugLabel: 'apps page');
  final scroll = ScrollController();
  final _selectedItem = GlobalKey();
  static const rowHeight = 56.0;

  @override
  void initState() {
    super.initState();
    _load();
    widget.shownAgain?.addListener(_onShown);
  }

  @override
  void dispose() {
    widget.shownAgain?.removeListener(_onShown);
    filter.dispose();
    filterFocus.dispose();
    pageFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _onShown() {
    _clearFilter();
    unawaited(_load());
    filterFocus.requestFocus();
  }

  // --- data ------------------------------------------------------------------

  void _takeGroups(Map<String, dynamic> result) {
    if (result['groups'] case final List list) {
      groups = [for (final g in list) Map<String, dynamic>.from(g)];
    }
    if (result['collapsed'] case final List list) collapsed = list.cast<String>();
  }

  void _takeSettings(Map<String, dynamic> settings) {
    this.settings = settings;
    view = AppView.values.byName(settings['view'] as String? ?? 'list');
    wideLayout = WideLayout.values.byName(settings['wide_layout'] as String? ?? 'folders');
    shownLayouts = [
      for (final l in WideLayout.values)
        if ((settings['shown_layouts'] as List? ?? const []).contains(l.name)) l,
    ];
    if (shownLayouts.isEmpty) shownLayouts = WideLayout.values;
    if (settings['icon_sizes'] case final Map m) {
      iconSizes = {for (final e in m.entries) '${e.key}': e.value as int};
    }
  }

  Future<void> _load() async {
    try {
      final result = await widget.core('apps.list');
      final settings = await widget.core('settings.get');
      if (!mounted) return;
      setState(() {
        apps = [for (final a in result['apps'] as List) Map<String, dynamic>.from(a)];
        byKey
          ..clear()
          ..addEntries(apps.map((a) => MapEntry(a['key'] as String, a)));
        _takeGroups(result);
        _takeSettings(settings);
        loading = false;
      });
      await _refreshSections();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _tell(trf('Could not read the apps ({0}).', [e]));
    }
  }

  bool get filtering => query.trim().isNotEmpty;

  /// launcher.refresh_list's shown(): not hidden (unless shown), name has the query.
  List<Map<String, dynamic>> get filtered {
    final q = query.toLowerCase().trim();
    return [
      for (final a in apps)
        if ((showHidden || a['hidden'] != true) && (a['name'] as String).toLowerCase().contains(q)) a,
    ];
  }

  static List<(String, List<String>)> _parseSections(Map<String, dynamic> result) => [
    for (final s in result['sections'] as List) (s['id'] as String, (s['keys'] as List).cast<String>()),
  ];

  Future<void> _refreshSections() async {
    final asked = ++_asked;
    final keys = [for (final a in filtered) a['key']];
    try {
      final byGroup = await widget.core('apps.sections', {'view': 'groups', 'keys': keys});
      final byView = view == AppView.origin
          ? await widget.core('apps.sections', {'view': 'origin', 'keys': keys})
          : byGroup;
      if (!mounted || asked != _asked) return;
      setState(() {
        _takeGroups(byGroup);
        groupSections = _parseSections(byGroup);
        sections = view == AppView.list ? [] : _parseSections(byView);
      });
    } on ServiceError catch (e) {
      _tell(trf('Could not sort the apps ({0}).', [e.code]));
    }
  }

  /// The narrow list's rows. Empty sections show while browsing (to fill
  /// them), never while filtering; Other and origin sections only with entries.
  List<ListItem> get rows {
    final list = filtered;
    if (view == AppView.list || sections.isEmpty) return [for (final a in list) AppRow(a)];
    final out = <ListItem>[];
    for (final (id, keys) in sections) {
      if (keys.isEmpty && (filtering || id == 'other' || id.startsWith('o-') || id == '_running')) continue;
      final folded = collapsed.contains(id) && !filtering;
      out.add(HeadingRow(id, keys.length, folded));
      if (!folded) {
        for (final k in keys) {
          if (byKey[k] case final app?) out.add(AppRow(app, id));
        }
      }
    }
    return out;
  }

  /// The entries the keys move through, in the order shown.
  List<Map<String, dynamic>> get visibleApps => wide
      ? overviewMembers
      : [
          for (final r in rows)
            if (r is AppRow) r.app,
        ];

  String groupName(String id) {
    if (originNames.containsKey(id)) return tr(originNames[id]!);
    if (id == 'all') return tr('All');
    if (id == 'other') return tr('Other');
    if (id == '_running') return tr('Running');
    final g = groups.where((g) => g['id'] == id).firstOrNull;
    if (g == null) return tr('Other');
    final name = g['name'] as String? ?? '';
    return name.isNotEmpty ? name : tr(builtinGroupNames[id] ?? id);
  }

  bool isNewGroup(String id) => groups.any((g) => g['id'] == id && g['new'] == true);

  // --- actions ---------------------------------------------------------------

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _launch(Map app, {String? action}) async {
    try {
      await widget.core(action == null ? 'apps.launch' : 'apps.action', {'key': app['key'], 'action': ?action});
      _clearFilter();
      // On Omarchy the window steps aside after a start, as the bar popup did.
      if (widget.desktop == 'omarchy') widget.onHide?.call();
    } on ServiceError {
      _tell(trf('{0} could not be started.', [app['name']]));
    }
  }

  void _clearFilter() {
    filter.clear();
    setState(() {
      query = '';
      selectedKey = null;
      searchFilter = null;
    });
    unawaited(_refreshSections());
  }

  Future<void> _saveSetting(String key, Object value) async {
    try {
      final settings = await widget.core('settings.set', {'key': key, 'value': value});
      if (mounted) setState(() => _takeSettings(settings));
      widget.onSettings?.call(settings);
    } on ServiceError {
      _tell(tr('Could not save the setting'));
    }
  }

  Future<void> setView(AppView next) async {
    if (next == view) return;
    setState(() => view = next);
    unawaited(_refreshSections());
    await _saveSetting('view', next.name);
  }

  /// set_wide_layout: the folders start on "All", where the folders are.
  Future<void> setWideLayout(WideLayout next) async {
    setState(() {
      wideLayout = next;
      overviewFilter = 'all';
      selectedKey = null;
    });
    await _saveSetting('wide_layout', next.name);
  }

  /// A group edit through the core; a refusal ("exists already") is shown.
  Future<Object?> _editGroups(String route, Map<String, dynamic> params) async {
    try {
      final result = await widget.core(route, params);
      setState(() => _takeGroups(result));
      return result['result'];
    } on ServiceError catch (e) {
      _tell(e.reason != null ? tr(e.reason!) : trf('That did not work ({0}).', [e.code]));
      return null;
    }
  }

  /// put_in_group: into group gid, at the end or next to target (dropped on it).
  Future<void> _place(String key, String gid, {String? target, bool after = false}) async {
    await _editGroups('groups.place', {'key': key, 'group': gid, 'target': ?target, 'after': after});
    await _load();
    if (mounted) setState(() => selectedKey = key);
  }

  Future<void> _putInGroup(Map app, String gid) => _place(app['key'] as String, gid);

  /// Groups move among themselves (Other stays last); entries go into any
  /// group, never into Running, All or an origin.
  bool _ownGroup(String id) => groups.any((g) => g['id'] == id);
  bool _canDropInto(String id) => _ownGroup(id) || id == 'other';

  /// What a group target does with a drop: an entry goes in, a group takes
  /// its place before or after it.
  void _dropOnGroup(String id, Dragged dragged, bool after) {
    switch (dragged) {
      case DraggedApp(:final key):
        _place(key, id);
      case DraggedGroup(id: final moved):
        _editGroups('groups.reorder', {'id': moved, 'target': id, 'after': after}).then((_) => _refreshSections());
    }
  }

  bool _acceptsOnGroup(String id, Dragged d) => switch (d) {
    DraggedApp() => _canDropInto(id),
    DraggedGroup(id: final moved) => _ownGroup(id) && moved != id,
  };

  Future<void> _setHidden(Map app, bool hidden) async {
    try {
      await widget.core('apps.hide', {'key': app['key'], 'hidden': hidden});
      await _load();
    } on ServiceError catch (e) {
      _tell(trf('Could not save ({0}).', [e.code]));
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) =>
      showDialog<String>(context: context, builder: (_) => NameDialog(title: title, initial: initial));

  Future<void> _newGroup({Map? app}) async {
    final name = await _askName(tr('New group'));
    if (name == null) return;
    final gid = await _editGroups('groups.add', {'name': name, 'key': ?app?['key']});
    if (gid != null) await _load();
  }

  Future<void> _groupMenu(String gid, Offset at) async {
    final ids = [for (final g in groups) g['id'] as String];
    final index = ids.indexOf(gid);
    final own = index >= 0;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (own) ...[
          PopupMenuItem(value: 'rename', child: MenuLine(Icons.edit, tr('Rename…'))),
          PopupMenuItem(value: 'up', enabled: index > 0, child: MenuLine(Icons.arrow_upward, tr('Move up'))),
          PopupMenuItem(
            value: 'down',
            enabled: index < ids.length - 1,
            child: MenuLine(Icons.arrow_downward, tr('Move down')),
          ),
          PopupMenuItem(value: 'delete', child: MenuLine(Icons.delete_outline, tr('Delete group'))),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(value: 'new', child: MenuLine(Icons.add, tr('New group…'))),
      ],
    );
    switch (choice) {
      case 'rename':
        final name = await _askName(tr('Rename group'), initial: groupName(gid));
        if (name != null) await _editGroups('groups.rename', {'id': gid, 'name': name});
      case 'up' || 'down':
        await _editGroups('groups.move', {'id': gid, 'delta': choice == 'up' ? -1 : 1});
        await _refreshSections();
      case 'delete':
        if (!mounted) return;
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(trf('Delete “{0}”?', [groupName(gid)])),
            content: Text(tr('Its entries move back.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Delete'))),
            ],
          ),
        );
        if (sure == true) {
          if (overviewFilter == gid) overviewFilter = 'all';
          await _editGroups('groups.delete', {'id': gid});
          await _load();
        }
      case 'new':
        await _newGroup();
    }
  }

  Future<void> _toggleGroup(String gid) => _editGroups('groups.toggle', {'id': gid});

  Future<void> _menu(Map app, Offset position) async {
    final actions = [for (final a in app['actions'] as List? ?? []) Map<String, dynamic>.from(a)];
    final hidden = app['hidden'] == true;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        PopupMenuItem(value: '\x00open', child: MenuLine(Icons.play_arrow, tr('Open'))),
        for (final a in actions) PopupMenuItem(value: a['id'] as String, child: MenuLine(Icons.launch, '${a['name']}')),
        const PopupMenuDivider(),
        PopupMenuItem(value: '\x00group', child: MenuLine(Icons.folder_outlined, tr('Move to group…'))),
        PopupMenuItem(value: '\x00details', child: MenuLine(Icons.info_outline, tr('Details…'))),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: '\x00hide',
          child: MenuLine(
            hidden ? Icons.visibility : Icons.visibility_off,
            hidden ? tr('Unhide from list') : tr('Hide from list'),
          ),
        ),
      ],
    );
    switch (choice) {
      case null:
        return;
      case '\x00open':
        return _launch(app);
      case '\x00details':
        return _details(app);
      case '\x00hide':
        return _setHidden(app, !hidden);
      case '\x00group':
        return _groupChoice(app, position);
      default:
        return _launch(app, action: choice);
    }
  }

  /// fill_group_choice: the group this entry belongs in.
  Future<void> _groupChoice(Map app, Offset at) async {
    final current = app['group'] as String?;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(enabled: false, child: Text(trf('Move {0} to', [app['name']]))),
        for (final gid in [for (final g in groups) g['id'] as String, 'other'])
          PopupMenuItem(value: gid, child: MenuLine(gid == current ? Icons.check : null, groupName(gid))),
        const PopupMenuDivider(),
        PopupMenuItem(value: '\x00new', child: MenuLine(Icons.add, tr('New group…'))),
      ],
    );
    if (choice == null) return;
    if (choice == '\x00new') return _newGroup(app: app);
    return _putInGroup(app, choice);
  }

  Future<void> _details(Map app) => showDialog(
    context: context,
    builder: (context) => AlertDialog(
      icon: AppIcon(app['icon_file'] as String?, size: 64),
      title: Text('${app['name']}'),
      content: SelectionArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((app['description'] as String? ?? '').isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('${app['description']}')),
            for (final (label, value) in [
              (tr('Starts'), app['exec']),
              (tr('Desktop file'), app['desktop_path']),
              (tr('Icon'), app['icon_file'] ?? app['icon']),
              (tr('Group'), groupName('${app['group']}')),
              (tr('Origin'), originNames['o-${app['origin']}']),
              (tr('Default for'), (app['roles'] as List? ?? []).join(', ')),
            ])
              if ('${value ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$label  ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: '$value'),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
    ),
  );

  Future<void> openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        core: widget.core,
        settings: settings,
        windowRounding: widget.windowRounding,
        onChanged: (fresh) {
          setState(() => _takeSettings(fresh));
          widget.onSettings?.call(fresh);
          unawaited(_refreshSections());
        },
      ),
    ),
  );

  /// Typing without the filter field (Settings › Filter field off): the
  /// keys still filter, the header shows what was typed.
  bool _typeIntoFilter(KeyEvent event) {
    if (filterFieldShown) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) return false;
    String next;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (query.isEmpty) return false;
      next = query.substring(0, query.length - 1);
    } else {
      final c = event.character;
      if (c == null || c.isEmpty || c.codeUnitAt(0) < 32 || c.codeUnitAt(0) == 127) return false;
      next = query + c;
    }
    filter.text = next;
    setState(() {
      query = next;
      selectedKey = null;
      if (next.trim().isEmpty) searchFilter = null;
    });
    unawaited(_refreshSections());
    return true;
  }

  // --- keys ------------------------------------------------------------------

  /// launcher.on_key / on_escape: Esc clears the filter, then leaves an open
  /// folder, then hides; Enter starts the selected app; the arrows move the
  /// selection; Ctrl+G: next view (narrow) or next group (wide).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (_typeIntoFilter(event)) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.escape) {
      if (query.isNotEmpty) {
        _clearFilter();
      } else if (wide && overviewFilter != 'all') {
        setState(() => overviewFilter = 'all');
      } else {
        widget.onHide?.call();
      }
      return KeyEventResult.handled;
    }
    if (keyboard.isControlPressed && key == LogicalKeyboardKey.keyG) {
      if (wide) {
        nextOverviewFilter(keyboard.isShiftPressed ? -1 : 1);
      } else {
        final order = AppView.values;
        setView(order[(order.indexOf(view) + 1) % order.length]);
      }
      return KeyEventResult.handled;
    }
    final list = visibleApps;
    var index = list.indexWhere((a) => a['key'] == selectedKey);
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (list.isNotEmpty) _launch(list[index < 0 ? 0 : index]);
      return KeyEventResult.handled;
    }
    final grid = wide && !showingFolders;
    final columns = grid ? _columns : 1;
    final move = switch (key) {
      LogicalKeyboardKey.arrowDown => columns,
      LogicalKeyboardKey.arrowUp => -columns,
      LogicalKeyboardKey.arrowRight when grid => 1,
      LogicalKeyboardKey.arrowLeft when grid => -1,
      _ => null,
    };
    if (move != null && list.isNotEmpty) {
      if (index < 0) index = 0;
      setState(() => selectedKey = list[(index + move).clamp(0, list.length - 1)]['key'] as String);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _selectedItem.currentContext;
        if (context != null) {
          Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
          Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
        }
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Focus(
      focusNode: pageFocus,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // grid_columns(card width) > 1: the overview, as gnome-launcher.
          wide = sizes.gridColumns(constraints.maxWidth.floor()) > 1;
          if (!filterFieldShown) {
            // No field to type in: the page takes the keys (typing filters).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final focused = FocusManager.instance.primaryFocus;
              if (mounted && (focused == null || focused == filterFocus || !focused.hasPrimaryFocus || focused.context == null)) {
                pageFocus.requestFocus();
              }
            });
          }
          return Column(
            children: [
              _header(),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : wide
                    ? _overviewBody()
                    : _narrowBody(),
              ),
              if (wide) _footerBar() else _narrowFooter(),
            ],
          );
        },
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    child: Row(
      children: [
        if (!filterFieldShown)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                query.isEmpty ? tr('App Manager') : trf('Filter: {0}', [query]),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          )
        else
          Expanded(
            child: TextField(
              controller: filter,
              focusNode: filterFocus,
              autofocus: true,
              decoration: InputDecoration(hintText: tr('Type to filter'), prefixIcon: Icon(Icons.search, size: 20)),
              onChanged: (text) {
                setState(() {
                  query = text;
                  selectedKey = null;
                  if (text.trim().isEmpty) searchFilter = null;
                });
                unawaited(_refreshSections());
              },
            ),
          ),
        if (!wide && viewButtons) ...[
          const SizedBox(width: 8),
          SegmentedButton<AppView>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity(horizontal: -4, vertical: -2)),
            segments: [
              ButtonSegment(value: AppView.list, icon: Icon(Icons.sort_by_alpha), tooltip: tr('A–Z (Ctrl+G)')),
              ButtonSegment(value: AppView.groups, icon: Icon(Icons.folder_outlined), tooltip: tr('Groups (Ctrl+G)')),
              ButtonSegment(
                value: AppView.origin,
                icon: Icon(Icons.inventory_2_outlined),
                tooltip: tr('By origin (Ctrl+G)'),
              ),
            ],
            selected: {view},
            onSelectionChanged: (s) => setView(s.first),
          ),
        ],
        _hiddenToggle(),
        IconButton(
          visualDensity: wide ? null : VisualDensity.compact,
          tooltip: tr('Reload'),
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          visualDensity: wide ? null : VisualDensity.compact,
          tooltip: tr('Settings'),
          onPressed: openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
  );

  Widget _hiddenToggle() {
    final count = apps.where((a) => a['hidden'] == true).length;
    if (count == 0) return const SizedBox.shrink();
    return IconButton(
      visualDensity: wide ? null : VisualDensity.compact,
      tooltip: showHidden ? tr('Hide hidden apps') : trf('Show hidden apps ({0})', [count]),
      isSelected: showHidden,
      onPressed: () {
        setState(() => showHidden = !showHidden);
        unawaited(_refreshSections());
      },
      icon: const Icon(Icons.visibility_outlined),
      selectedIcon: const Icon(Icons.visibility_off_outlined),
    );
  }

  // --- the narrow list -------------------------------------------------------

  Widget _empty() => Center(
    child: Text(
      query.isEmpty ? tr('No apps found.') : trf('No app matches “{0}”.', [query]),
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget _narrowBody() {
    final shown = rows;
    if (shown.isEmpty) return _empty();
    final first = visibleApps.firstOrNull;
    final selected = selectedKey ?? (filtering && first != null ? first['key'] as String : null);
    final slivers = <Widget>[];
    var chunk = <Map<String, dynamic>>[];
    String? chunkSection;
    void flush() {
      if (chunk.isEmpty) return;
      final members = chunk, section = chunkSection;
      slivers.add(
        SliverFixedExtentList.builder(
          itemExtent: rowHeight,
          itemCount: members.length,
          itemBuilder: (context, i) => _listRow(members[i], members[i]['key'] == selected, section),
        ),
      );
      chunk = [];
    }

    for (final row in shown) {
      switch (row) {
        case AppRow(:final app, :final section):
          chunkSection = section;
          chunk.add(app);
        case HeadingRow():
          flush();
          slivers.add(SliverToBoxAdapter(child: _heading(row)));
      }
    }
    flush();
    return CustomScrollView(
      controller: scroll,
      slivers: [
        for (final s in slivers) SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 8), sliver: s),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }

  Widget _narrowFooter() {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Text(trf('{0} of {1} apps', [filtered.length, apps.length]), style: muted),
            const Spacer(),
            if (view == AppView.groups) _newGroupButton(compact: false),
          ],
        ),
      ),
    );
  }

  Widget _newGroupButton({required bool compact}) => DropSlot(
    accepts: (d) => d is DraggedApp,
    onDrop: (d, _) => _newGroup(app: byKey[(d as DraggedApp).key]),
    child: Tooltip(
      message: tr('New group (or drop an app here to start one with it)'),
      child: compact
          ? FooterItem(icon: Icons.add, label: tr('New group'), onTap: _newGroup)
          : TextButton.icon(
              onPressed: _newGroup,
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: Text(tr('New group')),
            ),
    ),
  );

  /// make_group_row: click folds, ⋮ has rename, move, delete and new group.
  Widget _heading(HeadingRow row) {
    final scheme = Theme.of(context).colorScheme;
    final own = !row.id.startsWith('o-') && row.id != '_running';
    final heading = Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(corners(context).clamp(0, 8)),
        onTap: () => _toggleGroup(row.id),
        onSecondaryTapDown: own ? (d) => _groupMenu(row.id, d.globalPosition) : null,
        child: Container(
          height: 40,
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            children: [
              Icon(row.collapsed ? Icons.chevron_right : Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              if (isNewGroup(row.id)) ...[
                Tooltip(
                  message: tr('New group: drag apps onto it to fill it.'),
                  child: Icon(Icons.star, size: 14, color: scheme.primary),
                ),
                const SizedBox(width: 4),
              ],
              Text(groupName(row.id), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              CountChip(row.count),
              const Spacer(),
              if (own && row.id != 'other')
                Builder(
                  builder: (context) => IconButton(
                    tooltip: tr('Group actions'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.more_vert, size: 18),
                    onPressed: () {
                      final box = context.findRenderObject()! as RenderBox;
                      _groupMenu(row.id, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (view != AppView.groups || !_canDropInto(row.id)) return heading;
    final slot = DropSlot(
      accepts: (d) => _acceptsOnGroup(row.id, d),
      sided: (d) => d is DraggedGroup,
      onDrop: (d, after) => _dropOnGroup(row.id, d, after),
      child: heading,
    );
    if (!_ownGroup(row.id)) return slot;
    return Draggable<Dragged>(
      data: DraggedGroup(row.id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: groupDragFeedback(context, groupName(row.id)),
      childWhenDragging: Opacity(opacity: .4, child: heading),
      child: slot,
    );
  }

  /// An entry: its menu on right-click; it can be moved onto a group (and,
  /// with [section], dropped beside: before or after it in that group).
  Widget _entry(Map app, Widget child, {String? section, bool horizontal = false, bool movable = true}) {
    final shown = GestureDetector(
      onSecondaryTapDown: (d) => _menu(app, d.globalPosition),
      onLongPressStart: (d) => _menu(app, d.globalPosition),
      child: Opacity(opacity: app['hidden'] == true ? .5 : 1, child: child),
    );
    if (!movable) return shown;
    final key = app['key'] as String;
    final besides = section != null && _canDropInto(section);
    return Draggable<Dragged>(
      data: DraggedApp(key),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: appDragFeedback(app['icon_file'] as String?),
      childWhenDragging: Opacity(opacity: .35, child: shown),
      child: !besides
          ? shown
          : DropSlot(
              accepts: (d) => d is DraggedApp && d.key != key,
              sided: (_) => true,
              horizontal: horizontal,
              onDrop: (d, after) => _place((d as DraggedApp).key, section, target: key, after: after),
              child: shown,
            ),
    );
  }

  Widget _listRow(Map<String, dynamic> app, bool isSelected, String? section) {
    final scheme = Theme.of(context).colorScheme;
    final description = tr(app['description'] as String? ?? '');
    final size = (iconSizes['list'] ?? 32).toDouble();
    return _entry(
      app,
      ListTile(
        key: isSelected ? _selectedItem : null,
        selected: isSelected,
        selectedTileColor: scheme.secondaryContainer,
        selectedColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(corners(context).clamp(0, 10))),
        leading: AppIcon(app['icon_file'] as String?, size: size),
        title: Text('${app['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: description.isEmpty ? null : Text(description, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _launch(app),
      ),
      section: section,
      // Moving needs somewhere to go: the groups view's headings.
      movable: view == AppView.groups && section != null,
    );
  }
}

class CountChip extends StatelessWidget {
  const CountChip(this.count, {super.key});
  final int count;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Text('$count', style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
    );
  }
}

class MenuLine extends StatelessWidget {
  const MenuLine(this.icon, this.text, {super.key});
  final IconData? icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 22, child: icon == null ? null : Icon(icon, size: 16)),
      const SizedBox(width: 8),
      Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
    ],
  );
}

/// The group name dialog; it owns its text field's controller, which lives
/// until the dialog has animated out.
class NameDialog extends StatefulWidget {
  const NameDialog({super.key, required this.title, this.initial = ''});
  final String title;
  final String initial;
  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 40,
      decoration: InputDecoration(hintText: tr('Name')),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
      FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('Save'))),
    ],
  );
}
