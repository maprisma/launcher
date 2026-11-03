import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'drag_drop.dart';
import 'theme.dart';

enum Layout { list, icons }

/// The narrow window's views (launcher_core.saved_view).
enum AppView { list, groups, origin }

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

/// One heading or one entry of the shown list.
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
    this.initialLayout = Layout.list,
    this.shownAgain,
    this.onHide,
  });
  final CoreCall core;
  final String desktop;
  final Layout initialLayout;
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
  List<(String, List<String>)> sections = [];
  bool loading = true;
  bool showHidden = false;
  String query = '';
  AppView view = AppView.list;
  late Layout layout = widget.initialLayout;
  String? selectedKey;
  int _columns = 1;
  int _sectionsAsked = 0;
  final filter = TextEditingController();
  final filterFocus = FocusNode();
  final scroll = ScrollController();
  final _selectedItem = GlobalKey();
  static const rowHeight = 56.0, tileWidth = 132.0, tileHeight = 140.0;

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
    if (result['collapsed'] case final List list) {
      collapsed = list.cast<String>();
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
        view = AppView.values.byName(settings['view'] as String? ?? 'list');
        loading = false;
      });
      await _refreshSections();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _tell('Could not read the apps ($e).');
    }
  }

  /// launcher.refresh_list's shown(): not hidden (unless shown), name has the query.
  List<Map<String, dynamic>> get filtered {
    final q = query.toLowerCase().trim();
    return [
      for (final a in apps)
        if ((showHidden || a['hidden'] != true) &&
            (a['name'] as String).toLowerCase().contains(q))
          a,
    ];
  }

  Future<void> _refreshSections() async {
    if (view == AppView.list) {
      if (mounted) setState(() => sections = []);
      return;
    }
    final asked = ++_sectionsAsked;
    try {
      final result = await widget.core('apps.sections', {
        'view': view.name,
        'keys': [for (final a in filtered) a['key']],
      });
      if (!mounted || asked != _sectionsAsked) return;
      setState(() {
        _takeGroups(result);
        sections = [
          for (final s in result['sections'] as List)
            (s['id'] as String, (s['keys'] as List).cast<String>()),
        ];
      });
    } on ServiceError catch (e) {
      _tell('Could not sort the apps (${e.code}).');
    }
  }

  /// The rows shown: headings and entries. Empty sections show while
  /// browsing (to fill them), never while filtering; Other and the origin
  /// sections only with entries.
  List<ListItem> get rows {
    final list = filtered;
    if (view == AppView.list || sections.isEmpty) return [for (final a in list) AppRow(a)];
    final filtering = query.trim().isNotEmpty;
    final out = <ListItem>[];
    for (final (id, keys) in sections) {
      if (keys.isEmpty && (filtering || id == 'other' || id.startsWith('o-') || id == '_running')) {
        continue;
      }
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

  List<Map<String, dynamic>> get visibleApps => [
    for (final r in rows)
      if (r is AppRow) r.app,
  ];

  String groupName(String id) {
    if (originNames.containsKey(id)) return originNames[id]!;
    if (id == 'other') return 'Other';
    if (id == '_running') return 'Running';
    final g = groups.where((g) => g['id'] == id).firstOrNull;
    if (g == null) return 'Other';
    final name = g['name'] as String? ?? '';
    return name.isNotEmpty ? name : builtinGroupNames[id] ?? id;
  }

  // --- actions ---------------------------------------------------------------

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _launch(Map app, {String? action}) async {
    try {
      await widget.core(action == null ? 'apps.launch' : 'apps.action', {
        'key': app['key'],
        'action': ?action,
      });
      _clearFilter();
      // On Omarchy the window steps aside after a start, as the bar popup did.
      if (widget.desktop == 'omarchy') widget.onHide?.call();
    } on ServiceError {
      _tell('${app['name']} could not be started.');
    }
  }

  void _clearFilter() {
    filter.clear();
    setState(() {
      query = '';
      selectedKey = null;
    });
    unawaited(_refreshSections());
  }

  Future<void> setView(AppView next) async {
    if (next == view) return;
    setState(() => view = next);
    unawaited(_refreshSections());
    try {
      await widget.core('settings.set', {'key': 'view', 'value': next.name});
    } on ServiceError {
      _tell('Could not save the setting.');
    }
  }

  /// A group edit through the core; a refusal ("exists already") is shown.
  Future<Object?> _editGroups(String route, Map<String, dynamic> params) async {
    try {
      final result = await widget.core(route, params);
      setState(() => _takeGroups(result));
      return result['result'];
    } on ServiceError catch (e) {
      _tell(e.reason ?? 'That did not work (${e.code}).');
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
  /// group of the groups view, never into Running or an origin.
  bool _ownGroup(String id) => groups.any((g) => g['id'] == id);
  bool _canDropInto(String id) => _ownGroup(id) || id == 'other';

  void _dropOnHeading(String id, Dragged dragged, bool after) {
    switch (dragged) {
      case DraggedApp(:final key):
        _place(key, id);
      case DraggedGroup(id: final moved):
        _editGroups('groups.reorder', {'id': moved, 'target': id, 'after': after})
            .then((_) => _refreshSections());
    }
  }

  Future<void> _setHidden(Map app, bool hidden) async {
    try {
      await widget.core('apps.hide', {'key': app['key'], 'hidden': hidden});
      await _load();
    } on ServiceError catch (e) {
      _tell('Could not save (${e.code}).');
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  Future<void> _newGroup({Map? app}) async {
    final name = await _askName('New group');
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
          const PopupMenuItem(value: 'rename', child: _MenuLine(Icons.edit, 'Rename…')),
          PopupMenuItem(
            value: 'up',
            enabled: index > 0,
            child: const _MenuLine(Icons.arrow_upward, 'Move up'),
          ),
          PopupMenuItem(
            value: 'down',
            enabled: index < ids.length - 1,
            child: const _MenuLine(Icons.arrow_downward, 'Move down'),
          ),
          const PopupMenuItem(value: 'delete', child: _MenuLine(Icons.delete_outline, 'Delete group')),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(value: 'new', child: _MenuLine(Icons.add, 'New group…')),
      ],
    );
    switch (choice) {
      case 'rename':
        final name = await _askName('Rename group', initial: groupName(gid));
        if (name != null) await _editGroups('groups.rename', {'id': gid, 'name': name});
      case 'up' || 'down':
        await _editGroups('groups.move', {'id': gid, 'delta': choice == 'up' ? -1 : 1});
        await _refreshSections();
      case 'delete':
        if (!mounted) return;
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete “${groupName(gid)}”?'),
            content: const Text('Its entries move back.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (sure == true) {
          await _editGroups('groups.delete', {'id': gid});
          await _load();
        }
      case 'new':
        await _newGroup();
    }
  }

  Future<void> _toggleGroup(String gid) async {
    await _editGroups('groups.toggle', {'id': gid});
  }

  Future<void> _menu(Map app, Offset position) async {
    final actions = [
      for (final a in app['actions'] as List? ?? []) Map<String, dynamic>.from(a),
    ];
    final hidden = app['hidden'] == true;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: '\x00open', child: _MenuLine(Icons.play_arrow, 'Open')),
        for (final a in actions)
          PopupMenuItem(value: a['id'] as String, child: _MenuLine(Icons.launch, '${a['name']}')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '\x00group', child: _MenuLine(Icons.folder_outlined, 'Move to group…')),
        const PopupMenuItem(value: '\x00details', child: _MenuLine(Icons.info_outline, 'Details…')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: '\x00hide',
          child: _MenuLine(
            hidden ? Icons.visibility : Icons.visibility_off,
            hidden ? 'Unhide from list' : 'Hide from list',
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
        PopupMenuItem(enabled: false, child: Text('Move ${app['name']} to')),
        for (final gid in [for (final g in groups) g['id'] as String, 'other'])
          PopupMenuItem(
            value: gid,
            child: _MenuLine(gid == current ? Icons.check : null, groupName(gid)),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '\x00new', child: _MenuLine(Icons.add, 'New group…')),
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
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('${app['description']}'),
              ),
            for (final (label, value) in [
              ('Starts', app['exec']),
              ('Desktop file', app['desktop_path']),
              ('Icon', app['icon_file'] ?? app['icon']),
              ('Group', groupName('${app['group']}')),
              ('Origin', originNames['o-${app['origin']}']),
              ('Default for', (app['roles'] as List? ?? []).join(', ')),
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
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );

  // --- keys ------------------------------------------------------------------

  /// launcher.on_key: Esc clears the filter, then hides; Enter starts the
  /// selected app (or folds the group); the arrows move the selection.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final list = visibleApps;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.escape) {
      query.isNotEmpty ? _clearFilter() : widget.onHide?.call();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyG) {
      final order = AppView.values;
      setView(order[(order.indexOf(view) + 1) % order.length]);
      return KeyEventResult.handled;
    }
    var index = list.indexWhere((a) => a['key'] == selectedKey);
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (list.isNotEmpty) _launch(list[index < 0 ? 0 : index]);
      return KeyEventResult.handled;
    }
    final columns = layout == Layout.icons ? _columns : 1;
    final move = switch (key) {
      LogicalKeyboardKey.arrowDown => columns,
      LogicalKeyboardKey.arrowUp => -columns,
      LogicalKeyboardKey.arrowRight when layout == Layout.icons => 1,
      LogicalKeyboardKey.arrowLeft when layout == Layout.icons => -1,
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
  Widget build(BuildContext context) {
    final shown = rows;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final hiddenCount = apps.where((a) => a['hidden'] == true).length;
    final count = filtered.length;
    final first = visibleApps.firstOrNull?['key'];
    final selected = selectedKey ?? (query.isNotEmpty ? first : null);
    return Scaffold(
      body: Focus(
        onKeyEvent: _onKey,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: filter,
                      focusNode: filterFocus,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Type to filter',
                        prefixIcon: Icon(Icons.search, size: 20),
                      ),
                      onChanged: (text) {
                        setState(() {
                          query = text;
                          selectedKey = null;
                        });
                        unawaited(_refreshSections());
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<AppView>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: AppView.list, icon: Icon(Icons.sort_by_alpha), tooltip: 'A–Z (Ctrl+G)'),
                      ButtonSegment(value: AppView.groups, icon: Icon(Icons.folder_outlined), tooltip: 'Groups (Ctrl+G)'),
                      ButtonSegment(value: AppView.origin, icon: Icon(Icons.inventory_2_outlined), tooltip: 'By origin (Ctrl+G)'),
                    ],
                    selected: {view},
                    onSelectionChanged: (s) => setView(s.first),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<Layout>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: Layout.list, icon: Icon(Icons.view_list), tooltip: 'List'),
                      ButtonSegment(value: Layout.icons, icon: Icon(Icons.grid_view), tooltip: 'Icons'),
                    ],
                    selected: {layout},
                    onSelectionChanged: (s) => setState(() => layout = s.first),
                  ),
                  IconButton(tooltip: 'Reload', onPressed: _load, icon: const Icon(Icons.refresh)),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : shown.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty ? 'No apps found.' : 'No app matches “$query”.',
                        style: muted.copyWith(fontSize: 14),
                      ),
                    )
                  : _scroller(shown, selected),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Text('$count of ${apps.length} apps', style: muted),
                  const Spacer(),
                  if (hiddenCount > 0)
                    TextButton.icon(
                      onPressed: () {
                        setState(() => showHidden = !showHidden);
                        unawaited(_refreshSections());
                      },
                      icon: Icon(showHidden ? Icons.visibility_off : Icons.visibility, size: 16),
                      label: Text(showHidden ? 'Hide hidden apps' : 'Show hidden ($hiddenCount)'),
                    ),
                  if (view == AppView.groups)
                    DropSlot(
                      accepts: (d) => d is DraggedApp,
                      onDrop: (d, _) => _newGroup(app: byKey[(d as DraggedApp).key]),
                      child: Tooltip(
                        message: 'New group (or drop an app here to start one with it)',
                        child: TextButton.icon(
                          onPressed: _newGroup,
                          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                          label: const Text('New group'),
                        ),
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

  Widget _scroller(List<ListItem> shown, String? selected) => LayoutBuilder(
    builder: (context, constraints) {
      _columns = (constraints.maxWidth / tileWidth).floor().clamp(1, 99);
      final slivers = <Widget>[];
      var chunk = <Map<String, dynamic>>[];
      String? chunkSection;
      void flush() {
        if (chunk.isEmpty) return;
        final apps = chunk, section = chunkSection;
        slivers.add(
          layout == Layout.icons
              ? SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    mainAxisExtent: tileHeight,
                  ),
                  itemCount: apps.length,
                  itemBuilder: (context, i) => _tile(apps[i], apps[i]['key'] == selected, section),
                )
              : SliverFixedExtentList.builder(
                  itemExtent: rowHeight,
                  itemCount: apps.length,
                  itemBuilder: (context, i) => _listRow(apps[i], apps[i]['key'] == selected, section),
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
    },
  );

  /// make_group_row: click folds, ⋮ has rename, move, delete and new group.
  Widget _heading(HeadingRow row) {
    final scheme = Theme.of(context).colorScheme;
    final own = !row.id.startsWith('o-') && row.id != '_running';
    final isNew = groups.any((g) => g['id'] == row.id && g['new'] == true);
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
              if (isNew)
                Tooltip(
                  message: 'New group: drag apps onto it to fill it.',
                  child: Icon(Icons.star, size: 14, color: scheme.primary),
                ),
              if (isNew) const SizedBox(width: 4),
              Text(groupName(row.id), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${row.count}', style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ),
              const Spacer(),
              if (own && row.id != 'other')
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Group actions',
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
      accepts: (d) => switch (d) {
        DraggedApp() => true,
        DraggedGroup(:final id) => _ownGroup(row.id) && id != row.id,
      },
      sided: (d) => d is DraggedGroup,
      onDrop: (d, after) => _dropOnHeading(row.id, d, after),
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

  /// An entry: its menu on right-click; in the groups view it can be moved
  /// (onto a heading, another entry, or New group) and takes drops beside it.
  Widget _entry(Map app, Widget child, {String? section, bool horizontal = false}) {
    final shown = GestureDetector(
      onSecondaryTapDown: (d) => _menu(app, d.globalPosition),
      onLongPressStart: (d) => _menu(app, d.globalPosition),
      child: Opacity(opacity: app['hidden'] == true ? .5 : 1, child: child),
    );
    if (view != AppView.groups || section == null || !_canDropInto(section)) return shown;
    final key = app['key'] as String;
    return Draggable<Dragged>(
      data: DraggedApp(key),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: appDragFeedback(app['icon_file'] as String?),
      childWhenDragging: Opacity(opacity: .35, child: shown),
      child: DropSlot(
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
    final description = app['description'] as String? ?? '';
    return _entry(
      app,
      ListTile(
        key: isSelected ? _selectedItem : null,
        selected: isSelected,
        selectedTileColor: scheme.secondaryContainer,
        selectedColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(corners(context).clamp(0, 10))),
        leading: AppIcon(app['icon_file'] as String?, size: 32),
        title: Text('${app['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: description.isEmpty ? null : Text(description, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _launch(app),
      ),
      section: section,
    );
  }

  Widget _tile(Map<String, dynamic> app, bool isSelected, String? section) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(corners(context).clamp(0, 12));
    final description = '${app['description'] ?? ''}';
    return _entry(
      app,
      Padding(
        key: isSelected ? _selectedItem : null,
        padding: const EdgeInsets.all(4),
        child: Material(
          color: isSelected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: () => _launch(app),
            child: Tooltip(
              message: description.isEmpty ? '${app['name']}' : '${app['name']}\n$description',
              waitDuration: const Duration(milliseconds: 600),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    AppIcon(app['icon_file'] as String?, size: 64),
                    const SizedBox(height: 6),
                    Text(
                      '${app['name']}',
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      section: section,
      horizontal: true,
    );
  }
}

class _MenuLine extends StatelessWidget {
  const _MenuLine(this.icon, this.text);
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
