import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'theme.dart';

/// The runner's channel: "shown" (the window came back), "titlebar"
/// (dark or light), "hide".
const windowChannel = MethodChannel('appmanager/window');

/// Calls a core route: the Backend isolate in the app, the core itself in tests.
typedef CoreCall = Future<Map<String, dynamic>> Function(
  String method, [
  Map<String, dynamic> params,
]);

/// Counts the times the window was shown again (--toggle, a second start).
final shownAgain = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  final look = await backend.call('desktop.look').catchError((_) => <String, dynamic>{});
  windowChannel.setMethodCallHandler((call) async {
    if (call.method == 'shown') shownAgain.value++;
  });
  runApp(AppManager(core: backend.call, look: look));
}

class AppManager extends StatefulWidget {
  const AppManager({
    super.key,
    required this.core,
    required this.look,
    this.initialLayout = Layout.list,
  });
  final CoreCall core;
  final Layout initialLayout;
  final Map<String, dynamic> look;
  @override
  State<AppManager> createState() => _AppManagerState();
}

class _AppManagerState extends State<AppManager> with WidgetsBindingObserver {
  late Map<String, dynamic> look = widget.look;
  String cornersSetting = 'windows';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    shownAgain.addListener(_reloadLook);
    _syncTitlebar();
  }

  @override
  void dispose() {
    shownAgain.removeListener(_reloadLook);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _reloadLook();

  /// A theme switch while hidden shows when the window comes back.
  Future<void> _reloadLook() async {
    try {
      final fresh = await widget.core('desktop.look');
      if (mounted) setState(() => look = fresh);
      _syncTitlebar();
    } on Object {
      // The old look stays.
    }
  }

  void _syncTitlebar() {
    final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final dark = appTheme(platform, look['colors'] as Map? ?? {}, 12).brightness == Brightness.dark;
    windowChannel.invokeMethod('titlebar', dark).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius(cornersSetting, look['rounding'] as int?);
    return MaterialApp(
      title: 'App Manager',
      debugShowCheckedModeBanner: false,
      theme: appTheme(
        MediaQuery.platformBrightnessOf(context),
        look['colors'] as Map? ?? {},
        radius,
      ),
      home: AppsPage(
        core: widget.core,
        desktop: '${look['desktop'] ?? ''}',
        initialLayout: widget.initialLayout,
      ),
    );
  }
}

enum Layout { list, icons }

class AppsPage extends StatefulWidget {
  const AppsPage({
    super.key,
    required this.core,
    required this.desktop,
    this.initialLayout = Layout.list,
  });
  final Layout initialLayout;
  final CoreCall core;
  final String desktop;
  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  List<Map<String, dynamic>> apps = [];
  bool loading = true;
  String query = '';
  late Layout layout = widget.initialLayout;
  int selected = 0;
  int _columns = 1;
  final filter = TextEditingController();
  final filterFocus = FocusNode();
  final scroll = ScrollController();
  static const rowHeight = 56.0, tileWidth = 132.0, tileHeight = 140.0;

  @override
  void initState() {
    super.initState();
    _load();
    shownAgain.addListener(_onShown);
  }

  @override
  void dispose() {
    shownAgain.removeListener(_onShown);
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

  Future<void> _load() async {
    try {
      final result = await widget.core('apps.list');
      if (!mounted) return;
      setState(() {
        apps = [for (final a in result['apps'] as List) Map<String, dynamic>.from(a)];
        loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _tell('Could not read the apps ($e).');
    }
  }

  /// launcher.refresh_list: the query is a part of the name.
  List<Map<String, dynamic>> get shown {
    final q = query.toLowerCase().trim();
    return [
      for (final a in apps)
        if ((a['name'] as String).toLowerCase().contains(q)) a,
    ];
  }

  void _tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _launch(Map app, {String? action}) async {
    try {
      await widget.core(
        action == null ? 'apps.launch' : 'apps.action',
        {'key': app['key'], 'action': ?action},
      );
      _clearFilter();
      // On Omarchy the window steps aside after a start, as the bar popup did.
      if (widget.desktop == 'omarchy') _hide();
    } on ServiceError {
      _tell('${app['name']} could not be started.');
    }
  }

  void _hide() => windowChannel.invokeMethod('hide').ignore();

  void _clearFilter() {
    filter.clear();
    setState(() {
      query = '';
      selected = 0;
    });
  }

  /// launcher.on_key: Esc clears the filter, then hides; Enter starts the
  /// selected app; the arrows move the selection.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final list = shown;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      query.isNotEmpty ? _clearFilter() : _hide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (list.isNotEmpty) _launch(list[selected.clamp(0, list.length - 1)]);
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
      setState(() => selected = (selected + move).clamp(0, list.length - 1));
      _reveal();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _reveal() {
    if (!scroll.hasClients) return;
    final row = layout == Layout.icons ? selected ~/ _columns : selected;
    final extent = layout == Layout.icons ? tileHeight : rowHeight;
    final top = row * extent, bottom = top + extent;
    final view = scroll.position;
    if (top < view.pixels) {
      scroll.jumpTo(top);
    } else if (bottom > view.pixels + view.viewportDimension) {
      scroll.jumpTo(bottom - view.viewportDimension);
    }
  }

  Future<void> _menu(Map app, Offset position) async {
    final actions = [
      for (final a in app['actions'] as List? ?? []) Map<String, dynamic>.from(a),
    ];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: '\x00open', child: Text('Open')),
        if (actions.isNotEmpty) const PopupMenuDivider(),
        for (final a in actions)
          PopupMenuItem(value: a['id'] as String, child: Text('${a['name']}')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '\x00details', child: Text('Details')),
      ],
    );
    if (choice == null) return;
    if (choice == '\x00open') return _launch(app);
    if (choice == '\x00details') return _details(app);
    return _launch(app, action: choice);
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

  @override
  Widget build(BuildContext context) {
    final list = shown;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
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
                      onChanged: (text) => setState(() {
                        query = text;
                        selected = 0;
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<Layout>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: Layout.list,
                        icon: Icon(Icons.view_list),
                        tooltip: 'List',
                      ),
                      ButtonSegment(
                        value: Layout.icons,
                        icon: Icon(Icons.grid_view),
                        tooltip: 'Icons',
                      ),
                    ],
                    selected: {layout},
                    onSelectionChanged: (s) => setState(() => layout = s.first),
                  ),
                  IconButton(
                    tooltip: 'Reload',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty ? 'No apps found.' : 'No app matches “$query”.',
                        style: muted.copyWith(fontSize: 14),
                      ),
                    )
                  : layout == Layout.list
                  ? _listView(list)
                  : _iconView(list),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text('${list.length} of ${apps.length} apps', style: muted),
                  const Spacer(),
                  Text(widget.desktop, style: muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(Map app, Widget child) => GestureDetector(
    onSecondaryTapDown: (d) => _menu(app, d.globalPosition),
    onLongPressStart: (d) => _menu(app, d.globalPosition),
    child: child,
  );

  Widget _listView(List<Map<String, dynamic>> list) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(corners(context).clamp(0, 10));
    return ListView.builder(
      controller: scroll,
      itemExtent: rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final app = list[i];
        final description = app['description'] as String? ?? '';
        return _entry(
          app,
          ListTile(
            selected: i == selected,
            selectedTileColor: scheme.secondaryContainer,
            selectedColor: scheme.onSurface,
            shape: RoundedRectangleBorder(borderRadius: radius),
            leading: AppIcon(app['icon_file'] as String?, size: 32),
            title: Text('${app['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: description.isEmpty
                ? null
                : Text(description, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _launch(app),
          ),
        );
      },
    );
  }

  Widget _iconView(List<Map<String, dynamic>> list) => LayoutBuilder(
    builder: (context, constraints) {
      _columns = (constraints.maxWidth / tileWidth).floor().clamp(1, 99);
      final scheme = Theme.of(context).colorScheme;
      final radius = BorderRadius.circular(corners(context).clamp(0, 12));
      return GridView.builder(
        controller: scroll,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisExtent: tileHeight,
        ),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final app = list[i];
          final description = '${app['description'] ?? ''}';
          return _entry(
            app,
            Padding(
              padding: const EdgeInsets.all(4),
              child: Material(
                color: i == selected ? scheme.secondaryContainer : Colors.transparent,
                borderRadius: radius,
                child: InkWell(
                  borderRadius: radius,
                  onTap: () => _launch(app),
                  child: Tooltip(
                    message: description.isEmpty
                        ? '${app['name']}'
                        : '${app['name']}\n$description',
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
          );
        },
      );
    },
  );
}
