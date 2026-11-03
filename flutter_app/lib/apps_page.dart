import 'dart:async';

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart'
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
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'drag_drop.dart';
import 'i18n.dart';
import 'ask_page.dart';
import 'details_page.dart';
import 'icon_page.dart';
import 'plugins_page.dart';
import 'install_page.dart';
import 'shortcut_page.dart';
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

  /// The legend's choice: only entries with this mark (running, update, new,
  /// hidden); null: all. Esc or a second click clears it.
  String? markFilter;
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

  /// Running entries (keys), from the core's process scan every few seconds.
  Set<String> running = {};

  /// Omarchy: "active" (open windows) or "background" per running key.
  Map<String, String> runStates = const {};

  /// Updates: {"apps": {desktop path: [package, installed, available]},
  /// "flatpaks": {key: [installed, available]}}.
  Map<String, dynamic> updates = const {};

  /// apps.facts: {key: {kind, manager, package: {name, version, size, …}, file_size}}.
  Map<String, dynamic> facts = const {};

  /// Ask AI's helpers (ask.helpers): the header button shows whether one is ready.
  List<Map<String, dynamic>> askHelpers = const [];
  bool get askReady => askHelpers.any((h) => h['installed'] == true && h['signed_in'] == true);
  Timer? _poll;
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
    // refresh_running_async: the process scan runs in the core's isolate.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refreshRunning());
  }

  @override
  void dispose() {
    widget.shownAgain?.removeListener(_onShown);
    _poll?.cancel();
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
      await _refreshRunning(always: true);
      unawaited(_checkUpdates());
      unawaited(_loadFacts());
      unawaited(_loadHelpers());
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _tell(trf('Could not read the apps ({0}).', [e]));
    }
  }

  Future<void> _refreshRunning({bool always = false}) async {
    if (loading && !always) return;
    try {
      final result = await widget.core('apps.running');
      final now = (result['running'] as List).cast<String>().toSet();
      final states = Map<String, String>.from(result['states'] as Map? ?? const {});
      final changed = now.length != running.length || !now.containsAll(running) || !mapEquals(states, runStates);
      if (!mounted) return;
      if (changed) {
        setState(() {
          running = now;
          runStates = states;
        });
      }
      if (changed || always) await _refreshSections();
    } on ServiceError {
      // The marks wait for the next scan.
    }
  }

  /// updates.check (the core asks the package managers at most every 30
  /// minutes; [force] asks now).
  Future<void> _checkUpdates({bool force = false}) async {
    try {
      final result = await widget.core('updates.check', {'force': force});
      if (mounted) setState(() => updates = result);
    } on ServiceError {
      // No marks then.
    }
  }

  Future<void> _loadHelpers() async {
    try {
      final r = await widget.core('ask.helpers');
      if (mounted) setState(() => askHelpers = [for (final h in r['helpers'] as List) Map<String, dynamic>.from(h)]);
    } on ServiceError {
      // The button stays, without the state.
    }
  }

  Future<void> openAsk() => Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (_) => AskPage(
            core: widget.core,
            apps: byKey,
            onOpenInstall: openInstall,
            actions: (
              open: (app) => _launch(app),
              uninstall: _uninstall,
              update: _updateFlatpak,
              updateSystem: _updateSystem,
              details: _details,
              hasUpdate: (app) => updateNote(app) != null,
            ),
          ),
        ),
      )
      .then((_) => _loadHelpers());

  Future<void> _loadFacts() async {
    try {
      final result = await widget.core('apps.facts');
      if (mounted) setState(() => facts = Map<String, dynamic>.from(result['facts'] as Map));
    } on ServiceError {
      // Cards without size then.
    }
  }

  /// The app's own package: it installed the desktop entry, or the entry
  /// is a plain program (a web app's program is the browser, a command-line
  /// tool's maybe node: their packages are not the app).
  Map? ownPackage(Map app) {
    final f = facts[app['key']] as Map?;
    final pkg = f?['package'] as Map?;
    if (pkg == null) return null;
    if (f?['manager'] == 'flatpak' || f?['desktop_package'] == pkg['name']) return pkg;
    return f?['kind'] == 'app' ? pkg : null;
  }

  /// "142 MB" (pacman's bytes, an AppImage's file) or Flatpak's own text.
  String? sizeText(Map app) {
    final f = facts[app['key']] as Map?;
    if (f?['kind'] == 'webapp' || f?['kind'] == 'cli') return null;
    final pkg = ownPackage(app);
    if (pkg == null && f?['package'] != null) return null;
    if (pkg?['size_text'] case final String text when text.isNotEmpty) return text;
    final bytes = (pkg?['size'] ?? f?['file_size']) as int?;
    if (bytes == null) return null;
    final mb = bytes / (1024 * 1024);
    return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }

  /// Where it comes from, in a word: pacman, Flatpak, AppImage, web app, …
  String? sourceText(Map app) {
    final f = facts[app['key']] as Map?;
    final kind = f?['kind'];
    return switch (kind == 'webapp' || kind == 'cli' || ownPackage(app) == null && f?['manager'] == 'pacman'
        ? kind
        : f?['manager'] ?? kind) {
      'pacman' => 'pacman',
      'flatpak' => 'Flatpak',
      'appimage' => 'AppImage',
      'webapp' => tr('Web app'),
      'cli' => tr('Command-line tool'),
      _ => null,
    };
  }

  /// The entry's description, else its package's (Antigravity's review, point 7).
  String descriptionOf(Map app) {
    final own = tr((app['description'] as String? ?? '').trim());
    if (own.isNotEmpty) return own;
    return ownPackage(app)?['description'] as String? ?? '';
  }

  /// update_note: "Update available: …" for an entry with an update.
  String? updateNote(Map app) {
    if ((updates['flatpaks'] as Map?)?[app['key']] case final List v) {
      return '${v[0]}'.isNotEmpty ? trf('Update available: {0} → {1}', v) : tr('Update available');
    }
    if ((updates['apps'] as Map?)?[app['desktop_path']] case final List v) {
      return trf('Update available: {0} {1} → {2}', v);
    }
    return null;
  }

  bool isRunning(Map app) => running.contains(app['key']);

  /// has_mark: whether an entry shows this legend mark.
  bool hasMark(Map app, String mark) => switch (mark) {
    'running' => isRunning(app),
    'update' => updateNote(app) != null,
    'new' => app['new'] == true,
    'hidden' => app['hidden'] == true,
    _ => false,
  };

  /// legend_popover: every mark as it looks, what it means; a click shows
  /// only those entries.
  Future<void> _legend(Offset at) async {
    final marks = markColors(context);
    Widget dot(Color c) => Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
    final rows = [
      ('running', dot(marks.running), tr('Running')),
      ('update', dot(marks.update), tr('Update available: Update in its menu')),
      (
        'new',
        Icon(Icons.star_rounded, size: 16, color: marks.fresh),
        tr('New: installed recently (until you open it), or a new group (until it has an entry)'),
      ),
      ('hidden', const Icon(Icons.visibility_off, size: 15), tr('Hidden: shown only with the eye button')),
    ];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(enabled: false, child: Text(tr('What the marks mean'))),
        for (final (id, mark, text) in rows)
          PopupMenuItem(
            value: id,
            child: Tooltip(
              message: tr('Show only these (click again or Esc: all)'),
              child: Row(
                children: [
                  SizedBox(width: 22, child: Center(child: mark)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(text)),
                  if (markFilter == id)
                    const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.check, size: 16)),
                ],
              ),
            ),
          ),
      ],
    );
    if (choice == null) return;
    setState(() {
      markFilter = markFilter == choice ? null : choice;
      selectedKey = null;
    });
    unawaited(_refreshSections());
  }

  /// Settings' running_first (the header's ● button) in the narrow window;
  /// the wide window always has Running when anything runs.
  bool get runningFirst => settings['running_first'] == true;

  /// An icon with its marks (run dot, update dot, ★, hidden eye).
  Widget marked(Map app, double size) => MarkedIcon(
    app['icon_file'] as String?,
    size: size,
    running: isRunning(app),
    background: runStates[app['key']] == 'background',
    update: updateNote(app) != null,
    fresh: app['new'] == true,
    hidden: app['hidden'] == true,
  );

  /// The tooltip line for an entry's marks.
  String marksNote(Map app) => [
    if (isRunning(app))
      switch (runStates[app['key']]) {
        'active' => tr('Open windows'),
        'background' => tr('Running in background'),
        _ => tr('Running'),
      },
    if (app['new'] == true) tr('Newly installed'),
    ?updateNote(app),
    if (app['hidden'] == true) tr('Hidden'),
  ].join(' · ');

  bool get filtering => query.trim().isNotEmpty;

  /// launcher.refresh_list's shown(): not hidden (unless shown), name has the query.
  List<Map<String, dynamic>> get filtered {
    final q = query.toLowerCase().trim();
    return [
      for (final a in apps)
        if ((showHidden || a['hidden'] != true || markFilter == 'hidden') &&
            (markFilter == null || hasMark(a, markFilter!)) &&
            (a['name'] as String).toLowerCase().contains(q))
          a,
    ];
  }

  static List<(String, List<String>)> _parseSections(Map<String, dynamic> result) => [
    for (final s in result['sections'] as List) (s['id'] as String, (s['keys'] as List).cast<String>()),
  ];

  Future<void> _refreshSections() async {
    final asked = ++_asked;
    final keys = [for (final a in filtered) a['key']];
    try {
      // Running on top: always in the wide window's bar, in the narrow
      // views when the header's ● asks for it.
      final byGroup = await widget.core('apps.sections', {'view': 'groups', 'keys': keys, 'running': true});
      final byView = view == AppView.origin
          ? await widget.core('apps.sections', {'view': 'origin', 'keys': keys, 'running': runningFirst})
          : view == AppView.groups && !runningFirst
          ? await widget.core('apps.sections', {'view': 'groups', 'keys': keys})
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
    if (view == AppView.list || sections.isEmpty) {
      // Stable: running apps first, each part in the usual order.
      final ordered = runningFirst ? [...list.where(isRunning), ...list.where((a) => !isRunning(a))] : list;
      return [for (final a in ordered) AppRow(a)];
    }
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

  Future<String?> _askName(String title, {String initial = ''}) => showDialog<String>(
    context: context,
    builder: (_) => NameDialog(title: title, initial: initial),
  );

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
    final flatpakUpdate = (updates['flatpaks'] as Map?)?.containsKey(app['key']) == true;
    final omarchy = widget.desktop == 'omarchy';
    final hasWindows = runStates[app['key']] == 'active';
    // Both looked up at once; the app's own tray Quit only while it runs.
    Future<Object?> ask(String route, String field) async {
      try {
        return (await widget.core(route, {'key': app['key']}))[field];
      } on ServiceError {
        return null;
      }
    }

    Future<Object?> dockState() async {
      try {
        return await widget.core('dock.state');
      } on ServiceError {
        return null;
      }
    }

    final (adminCan, quitLabel, dock) = await (
      ask('apps.admin_check', 'can'),
      isRunning(app) ? ask('apps.quit_check', 'label') : Future<Object?>.value(),
      // Pin to dock: only while the dock (Omarchy) is switched on.
      omarchy ? dockState() : Future<Object?>.value(),
    ).wait;
    final dockSettings = dock is Map && dock['available'] == true ? dock['settings'] as Map? : null;
    final canPin = dockSettings?['dock_enabled'] == true && app['cli_command'] == null;
    final pinned = canPin && (dockSettings!['dock_pinned'] as List? ?? const []).contains(app['desktop_id']);
    final asAdmin = adminCan == true, canQuit = quitLabel is String;
    if (!mounted) return;
    final packageUpdate = (updates['apps'] as Map?)?.containsKey(app['desktop_path']) == true;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        PopupMenuItem(value: '\x00open', child: MenuLine(Icons.play_arrow, tr('Open'))),
        if (asAdmin)
          PopupMenuItem(value: '\x00admin', child: MenuLine(Icons.admin_panel_settings_outlined, tr('Open as administrator'))),
        if (omarchy) ...[
          PopupMenuItem(value: '\x00float', child: MenuLine(Icons.picture_in_picture_alt, tr('Open in floating window'))),
          PopupMenuItem(value: '\x00workspace', child: MenuLine(Icons.view_carousel_outlined, tr('Open on workspace'))),
        ],
        for (final a in actions) PopupMenuItem(value: a['id'] as String, child: MenuLine(Icons.launch, '${a['name']}')),
        if (hasWindows) ...[
          const PopupMenuDivider(),
          PopupMenuItem(value: '\x00switch', child: MenuLine(Icons.open_in_new, tr('Switch to window'))),
        ],
        if (canQuit) ...[
          if (!hasWindows) const PopupMenuDivider(),
          PopupMenuItem(value: '\x00quit', child: MenuLine(Icons.power_settings_new, tr('Quit'))),
        ],
        if (flatpakUpdate)
          PopupMenuItem(value: '\x00update', child: MenuLine(Icons.system_update_alt, tr('Update')))
        else if (packageUpdate)
          PopupMenuItem(value: '\x00system', child: MenuLine(Icons.system_update_alt, tr('Update system…'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: '\x00group', child: MenuLine(Icons.folder_outlined, tr('Move to group…'))),
        PopupMenuItem(value: '\x00details', child: MenuLine(Icons.info_outline, tr('Details…'))),
        PopupMenuItem(value: '\x00icon', child: MenuLine(Icons.image_outlined, tr('Change icon…'))),
        PopupMenuItem(value: '\x00shortcut', child: MenuLine(Icons.keyboard_outlined, tr('Shortcut…'))),
        if (canPin)
          PopupMenuItem(
            value: '\x00dock',
            child: MenuLine(Icons.push_pin_outlined, pinned ? tr('Unpin from dock') : tr('Pin to dock')),
          ),
        const PopupMenuDivider(),
        if ((app['uninstall'] != null || widget.desktop == 'omarchy') && app['cli_command'] == null)
          PopupMenuItem(value: '\x00uninstall', child: MenuLine(Icons.delete_outline, tr('Uninstall…'))),
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
      case '\x00icon':
        return _changeIcon(app);
      case '\x00shortcut':
        return _shortcut(app);
      case '\x00hide':
        return _setHidden(app, !hidden);
      case '\x00group':
        return _groupChoice(app, position);
      case '\x00update':
        return _updateFlatpak(app);
      case '\x00uninstall':
        return _uninstall(app);
      case '\x00switch':
        return _switchToWindow(app, position);
      case '\x00quit':
        return _quit(app);
      case '\x00admin':
        return _openSpecial(app, 'apps.admin_launch', const {});
      case '\x00float':
        return _openSpecial(app, 'apps.open_floating', const {});
      case '\x00workspace':
        return _workspaceChoice(app, position);
      case '\x00system':
        return _updateSystem();
      case '\x00dock':
        try {
          await widget.core('dock.pin', {'key': app['key'], 'pinned': !pinned});
        } on ServiceError catch (e) {
          _tell(trf('That did not work ({0}).', [e.code]));
        }
        return;
      default:
        return _launch(app, action: choice);
    }
  }

  static const _appsPages = {
    'Chrome': 'chrome://apps',
    'Chromium': 'chrome://apps',
    'Brave': 'brave://apps',
    'Edge': 'edge://apps',
    'Vivaldi': 'vivaldi://apps',
  };

  /// confirm_uninstall: how it goes (Flatpak, a package in a terminal, your
  /// own entry to the trash; a web app only its browser removes), with a
  /// warning for default apps and packages Omarchy installs itself.
  Future<void> _uninstall(Map app) async {
    Map<String, dynamic> plan;
    try {
      plan = await widget.core('apps.uninstall_plan', {'key': app['key']});
    } on ServiceError catch (e) {
      _tell(trf('That did not work ({0}).', [e.code]));
      return;
    }
    final kind = plan['kind'] as String?, what = '${plan['what']}';
    if (kind == null) {
      _tell('${trf('Could not uninstall {0}', [app['name']])}: ${tr('No package owns its desktop file.')}');
      return;
    }
    final manager = plan['manager'] as String?;
    final text = switch (kind) {
      'webapp' => trf(
        '{0} is a web app installed in {1}, so only {1} can uninstall it: open the app and choose ⋮ → Uninstall, or right-click it on {2} and choose Remove.',
        [app['name'], what, _appsPages[what] ?? tr('its apps page')],
      ),
      'flatpak' => trf('Removes the Flatpak {0}. Its data in ~/.var/app stays.', [what]),
      // Omarchy's own omarchy-remove-launcher-entry, by what it will do.
      'omarchy' => switch (plan['how']) {
        'webapp' => trf('Removes the web app {0}, as Omarchy\'s menu does.', [what]),
        'tui' => trf('Removes the terminal app {0}, as Omarchy\'s menu does.', [what]),
        'own' => trf('Deletes your own launcher entry for {0}.', [what]),
        'package' => trf('Removes the package {0} with pacman, in a terminal that asks for your password.', [what]),
        _ => trf('Removes the Flatpak {0}. Its data in ~/.var/app stays.', [what]),
      },
      'package' when manager == 'pacman' => trf(
        'Removes the package {0} with pacman, in a terminal that asks for your password.',
        [what],
      ),
      'package' => trf('Removes the package {0} with {1}, in a terminal that asks for your password.', [what, manager]),
      _ => trf('Moves {0} to the trash.', [what]),
    };
    final warnings = (plan['warnings'] as List? ?? const []).cast<String>();
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          kind == 'webapp'
              ? trf('How to uninstall {0}', [app['name']])
              : trf('Do you want to uninstall {0}?', [app['name']]),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text),
            for (final w in warnings) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  w == 'default'
                      ? trf('{0} is one of your default apps.', [app['name']])
                      : tr('Omarchy installs this package itself; removing it can break the desktop.'),
                ),
              ),
            ],
          ],
        ),
        actions: kind == 'webapp'
            ? [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Close')))]
            : [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(tr('Uninstall')),
                ),
              ],
      ),
    );
    if (go != true) return;
    if (kind == 'flatpak') _tell(trf('Uninstalling {0}…', [app['name']]));
    try {
      final result = await widget.core('apps.uninstall', {'key': app['key']});
      if (result['done'] == true) {
        _tell(
          kind == 'trash'
              ? '${trf('Uninstalled {0}', [app['name']])}: ${trf('{0} is in the trash.', [what])}'
              : trf('Uninstalled {0}', [app['name']]),
        );
        await _load();
      }
    } on ServiceError catch (e) {
      _tell(
        e.code == 'no_terminal'
            ? '${trf('Could not uninstall {0}', [app['name']])}: ${tr('No terminal found.')}'
            : trf('Could not uninstall {0}', [app['name']]),
      );
    }
  }

  Future<void> openInstall() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => InstallPage(core: widget.core)),
  ).then((_) => _load());

  /// switch_to_window: one window straight away; several: a list by title
  /// with its workspace.
  Future<void> _switchToWindow(Map app, Offset at) async {
    List windows;
    try {
      windows = (await widget.core('apps.windows', {'key': app['key']}))['windows'] as List;
    } on ServiceError {
      return;
    }
    if (windows.isEmpty || !mounted) return;
    var address = windows.first['address'] as String;
    if (windows.length > 1) {
      final chosen = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
        items: [
          PopupMenuItem(enabled: false, child: Text(trf('Switch to a window of {0}', [app['name']]))),
          for (final w in windows)
            PopupMenuItem(
              value: w['address'] as String,
              child: Row(
                children: [
                  if (w['workspace'] is int) CountChip(w['workspace'] as int),
                  const SizedBox(width: 8),
                  Flexible(child: Text('${w['title']}', overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
      );
      if (chosen == null) return;
      address = chosen;
    }
    widget.onHide?.call();
    try {
      await widget.core('window.focus', {'address': address});
    } on ServiceError {
      _tell(trf('{0} could not be started.', [app['name']]));
    }
  }

  /// Quit: the app's own tray Quit entry (a clean exit); App Manager never
  /// ends processes itself.
  Future<void> _quit(Map app) async {
    try {
      await widget.core('apps.quit', {'key': app['key']});
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (mounted) await _refreshRunning(always: true);
    } on ServiceError {
      _tell(trf('{0} could not be quit.', [app['name']]));
    }
  }

  Future<void> _openSpecial(Map app, String route, Map<String, dynamic> extra) async {
    try {
      await widget.core(route, {'key': app['key'], ...extra});
      _clearFilter();
      widget.onHide?.call();
    } on ServiceError {
      _tell(trf('{0} could not be started.', [app['name']]));
    }
  }

  /// Open on workspace ›: the workspaces in use (with their apps) and the next empty one.
  Future<void> _workspaceChoice(Map app, Offset at) async {
    Map<String, dynamic> found;
    try {
      found = await widget.core('workspaces.list');
    } on ServiceError {
      return;
    }
    if (!mounted) return;
    final free = found['free'] as int?;
    final chosen = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(enabled: false, child: Text(trf('Open {0} on', [app['name']]))),
        for (final w in found['workspaces'] as List)
          PopupMenuItem(
            value: w['id'] as int,
            child: Text(
              '${w['id']}${(w['apps'] as List).isEmpty ? '' : ' · ${(w['apps'] as List).take(3).join(', ')}'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (free != null) PopupMenuItem(value: free, child: Text(trf('{0} (empty)', [free]))),
      ],
    );
    if (chosen != null) await _openSpecial(app, 'apps.open_on_workspace', {'workspace': chosen});
  }

  /// update_flatpak: this one app, in the background; says how it went.
  Future<void> _updateFlatpak(Map app) async {
    _tell(trf('Updating {0}…', [app['name']]));
    try {
      final result = await widget.core('updates.flatpak', {'key': app['key']});
      if (!mounted) return;
      setState(() => updates = result);
      _tell(trf('{0} updated', [app['name']]));
    } on ServiceError catch (e) {
      _tell('${trf('{0} could not be updated', [app['name']])}${e.reason == null ? '' : ': ${e.reason}'}');
    }
  }

  /// update_system: the desktop's updater, or the package manager's full
  /// update in a terminal (never one package alone on Arch).
  Future<void> _updateSystem() async {
    try {
      await widget.core('updates.system');
      widget.onHide?.call();
    } on ServiceError {
      _tell(tr('Could not start the update'));
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

  Future<void> _details(Map app) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DetailsPage(
        core: widget.core,
        app: app,
        facts: facts[app['key']] as Map?,
        groupName: groupName('${app['group']}'),
        originName: originNames['o-${app['origin']}'] == null ? null : tr(originNames['o-${app['origin']}']!),
      ),
    ),
  );

  /// Shortcut…: global keys that open the app (shortcut_page.dart).
  Future<void> _shortcut(Map app) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ShortcutPage(core: widget.core, app: app)),
  );

  /// Change icon: the theme's text colour tints one-colour icons.
  Future<void> _changeIcon(Map app) async {
    final fg = Theme.of(context).colorScheme.onSurface;
    final hex = '#${(fg.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => IconPage(core: widget.core, app: app, foreground: hex)),
    );
    if (changed == true) await _load();
  }

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
      } else if (markFilter != null) {
        setState(() => markFilter = null);
        unawaited(_refreshSections());
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
              if (mounted &&
                  (focused == null || focused == filterFocus || !focused.hasPrimaryFocus || focused.context == null)) {
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
                query.isEmpty ? tr('Maprisma Launcher') : trf('Filter: {0}', [query]),
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
        _runningToggle(),
        Builder(
          builder: (context) => IconButton(
            visualDensity: wide ? null : VisualDensity.compact,
            tooltip: tr('What the marks mean'),
            isSelected: markFilter != null,
            onPressed: () {
              final box = context.findRenderObject()! as RenderBox;
              _legend(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
            },
            icon: const Icon(Icons.info_outline),
            selectedIcon: const Icon(Icons.filter_alt),
          ),
        ),
        _hiddenToggle(),
        IconButton(
          visualDensity: wide ? null : VisualDensity.compact,
          tooltip: tr('Reload'),
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
        // Always there (Antigravity's review, point 1): a dot while no helper is ready.
        IconButton(
          visualDensity: wide ? null : VisualDensity.compact,
          tooltip: askReady ? tr('Ask AI') : tr('Ask AI (set up a helper first)'),
          onPressed: openAsk,
          icon: Badge(
            isLabelVisible: !askReady,
            smallSize: 7,
            backgroundColor: markColors(context).update,
            child: Icon(
              askReady ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              color: askReady ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
        ),
        if (widget.desktop == 'omarchy')
          IconButton(
            visualDensity: wide ? null : VisualDensity.compact,
            tooltip: tr('Omarchy plugins'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => PluginsPage(core: widget.core, onHide: widget.onHide)),
            ),
            icon: const Icon(Icons.extension_outlined),
          ),
        IconButton(
          visualDensity: wide ? null : VisualDensity.compact,
          tooltip: tr('Install apps'),
          onPressed: openInstall,
          icon: const Icon(Icons.add_box_outlined),
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

  /// The header's ● (narrow window): running apps first, or by name.
  Widget _runningToggle() {
    if (wide) return const SizedBox.shrink();
    final marks = markColors(context);
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: runningFirst ? tr('Sort apps by name') : tr('Show running apps first'),
      isSelected: runningFirst,
      onPressed: () async {
        await _saveSetting('running_first', !runningFirst);
        unawaited(_refreshSections());
      },
      icon: Icon(Icons.fiber_manual_record_outlined, color: running.isNotEmpty ? marks.running : null),
      selectedIcon: Icon(Icons.fiber_manual_record, color: marks.running),
    );
  }

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
                  child: Icon(Icons.star_rounded, size: 15, color: markColors(context).fresh),
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
        leading: Tooltip(message: marksNote(app), child: marked(app, size)),
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
