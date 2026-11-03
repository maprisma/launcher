part of 'apps_page.dart';

/// The wide window (launcher.py's overview): folders, cards or icons, with
/// the groups in a bar at the bottom.
extension Overview on AppsPageState {
  void _update(VoidCallback change) {
    if (mounted) {
      // ignore: invalid_use_of_protected_member
      setState(change);
    }
  }

  /// overview_sections: All, then the groups. Every group stays, empty or
  /// not (a place to drag to); Other only with entries or while filtering.
  List<(String, List<String>)> get overviewSections => [
    ('all', [for (final a in filtered) a['key'] as String]),
    for (final (id, keys) in groupSections)
      // Running only while something runs; Other with entries or filtering.
      if (id == '_running' ? keys.isNotEmpty : (keys.isNotEmpty || id != 'other' || filtering)) (id, keys),
  ];

  /// The group shown: during a search the one picked for it (else All).
  String get wantedFilter {
    final wanted = filtering ? (searchFilter ?? 'all') : overviewFilter;
    return overviewSections.any((s) => s.$1 == wanted) ? wanted : 'all';
  }

  /// showing_folders: the folder layout's start page, not filtering.
  bool get showingFolders => wideLayout == WideLayout.folders && wantedFilter == 'all' && !filtering;

  List<Map<String, dynamic>> get overviewMembers {
    if (showingFolders) return const [];
    if (showingCube) {
      final wanted = cubeFront;
      final keys = cubeSections.where((s) => s.$1 == wanted).firstOrNull?.$2 ?? const [];
      return [for (final k in keys) ?byKey[k]];
    }
    final wanted = wantedFilter;
    final keys = overviewSections.firstWhere((s) => s.$1 == wanted).$2;
    return [for (final k in keys) ?byKey[k]];
  }

  void setOverviewFilter(String gid) => _update(() {
    if (filtering) {
      searchFilter = gid; // For this search only.
    } else {
      overviewFilter = gid;
    }
    selectedKey = null;
  });

  void nextOverviewFilter(int step) {
    if (showingCube) return turnCube(step);
    final ids = [for (final s in overviewSections) s.$1];
    final position = ids.indexOf(wantedFilter);
    setOverviewFilter(ids[((position < 0 ? 0 : position) + step) % ids.length]);
  }

  Widget _overviewBody() => LayoutBuilder(
    builder: (context, constraints) {
      // The card width as launcher.py measures it (its padding is in the math).
      final cardWidth = constraints.maxWidth.floor();
      final height = constraints.maxHeight.floor();
      if (showingFolders) return _folders(cardWidth, height);
      if (showingCube) return _cube(cardWidth, height);
      final members = overviewMembers;
      final open = !filtering && wantedFilter != 'all';
      return Column(
        children: [
          if (open) _openFolderBar(),
          Expanded(child: members.isEmpty ? _empty() : _grid(members, cardWidth)),
        ],
      );
    },
  );

  /// In a folder: where you are and the way back (Esc, as gnome-launcher).
  Widget _openFolderBar() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () => setOverviewFilter('all'),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: Text(tr('All')),
          ),
          Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(groupName(wantedFilter), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text(tr('Esc goes back'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  // --- folders -----------------------------------------------------------------

  /// The groups the folders (and the cube's faces) show.
  List<(String, List<String>)> get folderSections => [
    for (final (id, keys) in overviewSections)
      if (id != 'all' && (keys.isNotEmpty || (id != '_running' && id != 'other'))) (id, keys),
  ];

  Widget _folders(int cardWidth, int height) {
    final folders = folderSections;
    if (folders.isEmpty) return _empty();
    final (columns, icon) = sizes.folderFit(folders.length, cardWidth, height);
    final iconsHeight = sizes.folderIconsHeight(folders.length, columns, icon, height);
    final rowsHeight = sizes.folderRows * (icon + 14) + (sizes.folderRows - 1) * 6;
    final tileHeight = sizes.folderTileSize(icon).$2 - rowsHeight + iconsHeight;
    final drawn = sizes.folderAppIcon(icon, iconSizes['folders'] ?? 100);
    return GridView.builder(
      controller: scroll,
      padding: const EdgeInsets.symmetric(horizontal: sizes.cardPadding / 2),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: tileHeight.toDouble(),
        crossAxisSpacing: sizes.tileSpacing.toDouble(),
        mainAxisSpacing: sizes.tileSpacing.toDouble(),
      ),
      itemCount: folders.length,
      itemBuilder: (context, i) => _folderTile(folders[i].$1, folders[i].$2, icon, drawn),
    );
  }

  /// make_folder_tile: its icons (nine show, more scroll inside), the name
  /// under it. A click beside the icons opens the group; right click: its
  /// menu; the folder moves among the groups, an icon onto another group.
  Widget _folderTile(String gid, List<String> keys, int icon, int drawn) {
    final scheme = Theme.of(context).colorScheme;
    final radius = corners(context);
    final members = [for (final k in keys) ?byKey[k]];
    final overflow = members.length > sizes.folderColumns * sizes.folderRows;
    final cell = (icon + 14).toDouble();
    final frame = Container(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          // The rows spread over the folder's height, unless they scroll.
          final rowExtent = overflow ? cell : (box.maxHeight - 2 * 6) / sizes.folderRows;
          return GridView.builder(
            physics: overflow ? null : const NeverScrollableScrollPhysics(),
            primary: false,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: sizes.folderColumns,
              mainAxisExtent: rowExtent < cell ? cell : rowExtent,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: members.length,
            itemBuilder: (context, i) => _folderIcon(members[i], gid, drawn.toDouble()),
          );
        },
      ),
    );
    final name = Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(
        TextSpan(
          children: [
            if (isNewGroup(gid))
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Icon(Icons.star_rounded, size: 14, color: markColors(context).fresh),
                ),
              ),
            TextSpan(text: groupName(gid)),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
    final tile = Tooltip(
      message:
          '${groupName(gid)} · ${trn('{0} entry', '{0} entries', members.length)}\n'
          '${tr('Click to open the group, or an icon to start it. Esc goes back.')}',
      waitDuration: const Duration(milliseconds: 800),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => setOverviewFilter(gid),
        onSecondaryTapDown: _canDropInto(gid) && gid != 'other' ? (d) => _groupMenu(gid, d.globalPosition) : null,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              Expanded(child: frame),
              name,
            ],
          ),
        ),
      ),
    );
    if (!_canDropInto(gid)) return tile;
    final slot = DropSlot(
      accepts: (d) => _acceptsOnGroup(gid, d),
      sided: (d) => d is DraggedGroup,
      horizontal: true,
      onDrop: (d, after) => _dropOnGroup(gid, d, after),
      child: tile,
    );
    if (!_ownGroup(gid)) return slot;
    return Draggable<Dragged>(
      data: DraggedGroup(gid),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: groupDragFeedback(context, groupName(gid)),
      childWhenDragging: Opacity(opacity: .4, child: tile),
      child: slot,
    );
  }

  Widget _folderIcon(Map<String, dynamic> app, String gid, double size) {
    return _entry(
      app,
      Tooltip(
        message: [app['name'], marksNote(app)].where((t) => '$t'.isNotEmpty).join('\n'),
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _launch(app),
          child: Center(child: marked(app, size)),
        ),
      ),
      section: gid,
      horizontal: true,
    );
  }

  // --- cards and icons ---------------------------------------------------------

  Widget _grid(List<Map<String, dynamic>> members, int cardWidth) {
    final icons = wideLayout == WideLayout.icons;
    final iconSize = iconSizes[icons ? 'icons' : 'cards'] ?? (icons ? 72 : 44);
    _columns = icons ? sizes.iconColumns(cardWidth, iconSize) : sizes.gridColumns(cardWidth);
    final selected = selectedKey ?? (filtering ? members.first['key'] : null);
    final extent = icons ? iconSize + 8 + 36 + 24.0 : iconSize + sizes.tileTextHeight + 26.0;
    return GridView.builder(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(sizes.cardPadding / 2, 0, sizes.cardPadding / 2, 8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        mainAxisExtent: extent,
        crossAxisSpacing: sizes.tileSpacing.toDouble(),
        mainAxisSpacing: sizes.tileSpacing.toDouble(),
      ),
      itemCount: members.length,
      itemBuilder: (context, i) {
        final app = members[i];
        final isSelected = app['key'] == selected;
        return icons ? _iconTile(app, isSelected, iconSize.toDouble()) : _card(app, isSelected, iconSize.toDouble());
      },
    );
  }

  /// make_tile: icon, ⋮ for the actions, name, two lines of description.
  Widget _card(Map<String, dynamic> app, bool isSelected, double iconSize) {
    final scheme = Theme.of(context).colorScheme;
    final description = descriptionOf(app);
    final facts = [?sizeText(app), ?sourceText(app)].join(' · ');
    final radius = BorderRadius.circular(corners(context));
    return _entry(
      app,
      Material(
        key: isSelected ? _selectedItem : null,
        color: isSelected ? scheme.secondaryContainer : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: () => _launch(app),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    marked(app, iconSize),
                    const Spacer(),
                    Builder(
                      builder: (context) => IconButton(
                        tooltip: tr('App actions'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.more_vert, size: 18),
                        onPressed: () {
                          final box = context.findRenderObject()! as RenderBox;
                          _menu(app, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${app['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Expanded(
                  child: Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
                // Size and where it comes from (Uwe: more facts on the cards).
                if (facts.isNotEmpty)
                  Text(
                    facts,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                if (app['hidden'] == true)
                  Row(
                    children: [
                      Icon(Icons.visibility_off, size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(tr('Hidden'), style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// make_icon_tile: a large icon, the name centred under it.
  Widget _iconTile(Map<String, dynamic> app, bool isSelected, double iconSize) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(corners(context).clamp(0, 12));
    final description = tr((app['description'] as String? ?? '').trim());
    return _entry(
      app,
      Material(
        key: isSelected ? _selectedItem : null,
        color: isSelected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => _launch(app),
          child: Tooltip(
            message: [
              description.isEmpty ? '${app['name']}' : '${app['name']} — $description',
              marksNote(app),
            ].where((t) => t.isNotEmpty).join('\n'),
            waitDuration: const Duration(milliseconds: 600),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  marked(app, iconSize),
                  const SizedBox(height: 8),
                  Text(
                    '${app['name']}',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, height: 1.2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- the cube ----------------------------------------------------------------

  /// The cube: one face per group (or origin), not while filtering (then the grid).
  bool get showingCube => wideLayout == WideLayout.cube && !filtering;

  /// The cube's faces: the groups, or (flipped vertically) where the apps come from.
  List<(String, List<String>)> get cubeSections {
    if (!cubeByOrigin) return folderSections;
    final nonEmpty = [
      for (final (id, keys) in originSections)
        if (keys.isNotEmpty) (id, keys),
    ];
    return nonEmpty.isNotEmpty ? nonEmpty : originSections;
  }

  /// The front face's group (or origin): the chosen one, else the first.
  String? get cubeFront {
    final faces = cubeSections;
    if (faces.isEmpty) return null;
    final wanted = filtering ? (searchFilter ?? 'all') : overviewFilter;
    return faces.any((f) => f.$1 == wanted) ? wanted : faces.first.$1;
  }

  /// Left/Right, Ctrl+G, the wheel: the next face round the cube.
  void turnCube(int step) {
    final ids = [for (final f in cubeSections) f.$1];
    if (ids.isEmpty) return;
    final at = ids.indexOf(cubeFront ?? ids.first);
    cubeDirection = step < 0 ? -1 : 1;
    setOverviewFilter(ids[((at < 0 ? 0 : at) + step) % ids.length]);
  }

  /// Vertical flip (the bottom-right option button, Ctrl+Up/Down, or a
  /// vertical drag): switch the cube between groups and origins.
  void flipCube() => _update(() {
    cubeByOrigin = !cubeByOrigin;
    overviewFilter = 'all';
    selectedKey = null;
  });

  Widget _cube(int cardWidth, int height) {
    final faces = cubeSections;
    if (faces.isEmpty) return _empty();
    final front = faces.indexWhere((f) => f.$1 == cubeFront);
    return _CubeOverview(
      faces: [for (final f in faces) f.$1],
      front: front < 0 ? 0 : front,
      direction: cubeDirection,
      byOrigin: cubeByOrigin,
      onFront: (i) => setOverviewFilter(faces[i].$1),
      onFlip: flipCube,
      face: (i, width, isFront) => _cubeFace(faces[i].$1, faces[i].$2, width, isFront),
    );
  }

  /// A face: the group's name, count and menu over its apps (icons with
  /// names); apps start, open their menu and drag as everywhere.
  Widget _cubeFace(String gid, List<String> keys, double width, bool isFront) {
    final scheme = Theme.of(context).colorScheme;
    final radius = corners(context);
    final members = [for (final k in keys) ?byKey[k]];
    final iconSize = (iconSizes['icons'] ?? 72).toDouble().clamp(32.0, 96.0);
    final columns = math.max(1, ((width - 24) / (iconSize + 40)).floor());
    if (isFront) _columns = columns;
    final selected = isFront ? selectedKey : null;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 6),
      child: Row(
        children: [
          if (isNewGroup(gid))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.star_rounded, size: 16, color: markColors(context).fresh),
            ),
          Flexible(
            child: Text(
              groupName(gid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(10)),
            child: Text('${members.length}', style: TextStyle(fontSize: 11.5, color: scheme.onSecondaryContainer)),
          ),
          const Spacer(),
          if (_ownGroup(gid))
            Builder(
              builder: (context) => IconButton(
                tooltip: tr('Group actions'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_vert, size: 18),
                onPressed: () {
                  final box = context.findRenderObject()! as RenderBox;
                  _groupMenu(gid, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
              ),
            )
          else
            const SizedBox(height: 40),
        ],
      ),
    );
    final grid = members.isEmpty
        ? Center(
            child: Text(tr('Drag apps here'), style: TextStyle(color: scheme.onSurfaceVariant)),
          )
        : GridView.builder(
            controller: isFront ? scroll : null,
            primary: false,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: iconSize + 8 + 36 + 24,
              crossAxisSpacing: sizes.tileSpacing.toDouble(),
              mainAxisSpacing: sizes.tileSpacing.toDouble(),
            ),
            itemCount: members.length,
            itemBuilder: (context, i) => _iconTile(members[i], members[i]['key'] == selected, iconSize),
          );
    Widget card = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: isFront ? scheme.primary.withValues(alpha: .6) : scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [header, Divider(height: 1, color: scheme.outlineVariant), Expanded(child: grid)]),
    );
    if (_canDropInto(gid)) {
      card = DropSlot(
        accepts: (d) => d is! DraggedGroup && _acceptsOnGroup(gid, d),
        onDrop: (d, after) => _dropOnGroup(gid, d, after),
        child: card,
      );
    }
    return card;
  }

  // --- the footer --------------------------------------------------------------

  /// fill_filter_bar: All and the groups (each a place to drop an entry or
  /// a group), New group last; the layouts on the right.
  Widget _footerBar() {
    final scheme = Theme.of(context).colorScheme;
    // The cube has no "All" page: its front face is the chosen one.
    final wanted = showingCube ? (cubeFront ?? wantedFilter) : wantedFilter;
    final barSections = showingCube && cubeByOrigin
        ? [('all', [for (final a in filtered) a['key'] as String]), ...cubeSections]
        : overviewSections;
    final strip = ScrollController();
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      height: 72,
      child: Row(
        children: [
          Expanded(
            child: Listener(
              // The wheel scrolls the row sideways.
              onPointerSignal: (event) {
                if (event is PointerScrollEvent && strip.hasClients) {
                  final delta = event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
                  strip.jumpTo((strip.offset + delta).clamp(0, strip.position.maxScrollExtent));
                }
              },
              child: ListView(
                controller: strip,
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (id, keys) in barSections) _footerChip(id, keys.length, id == wanted),
                  if (!(showingCube && cubeByOrigin)) _newGroupButton(compact: true),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              trn('{0} app', '{0} apps', filtered.length),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          if (shownLayouts.length > 1)
            SegmentedButton<WideLayout>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final layout in shownLayouts)
                  ButtonSegment(
                    value: layout,
                    tooltip: switch (layout) {
                      WideLayout.folders => tr('Folders'),
                      WideLayout.cards => tr('Cards'),
                      WideLayout.icons => tr('Icons'),
                      WideLayout.cube => tr('Cube'),
                    },
                    icon: Icon(switch (layout) {
                      WideLayout.folders => Icons.folder_copy_outlined,
                      WideLayout.cards => Icons.view_agenda_outlined,
                      WideLayout.icons => Icons.apps,
                      WideLayout.cube => Icons.view_in_ar_outlined,
                    }),
                  ),
              ],
              selected: {wideLayout},
              onSelectionChanged: (s) => setWideLayout(s.first),
            ),
        ],
      ),
    );
  }

  Widget _footerChip(String id, int count, bool on) {
    final item = Tooltip(
      message:
          '${groupName(id)} · ${trn('{0} entry', '{0} entries', count)}\n${id == 'all' ? tr('Show everything (Ctrl+G: next group)') : tr('Show only this group (Ctrl+G: next group). Right click: rename, move or delete.')}',
      waitDuration: const Duration(milliseconds: 600),
      child: FooterItem(
        icon: id == 'all'
            ? Icons.home_outlined
            : id == '_running'
            ? Icons.play_circle_outline
            : id.startsWith('o-')
            ? Icons.inventory_2_outlined
            : Icons.folder_outlined,
        label: groupName(id),
        star: isNewGroup(id),
        on: on,
        onTap: () => setOverviewFilter(id),
        onSecondaryTap: _ownGroup(id) ? (at) => _groupMenu(id, at) : null,
      ),
    );
    if (id == 'all' || !_canDropInto(id)) return item;
    final slot = DropSlot(
      accepts: (d) => _acceptsOnGroup(id, d),
      sided: (d) => d is DraggedGroup,
      horizontal: true,
      onDrop: (d, after) => _dropOnGroup(id, d, after),
      child: item,
    );
    if (!_ownGroup(id)) return slot;
    return Draggable<Dragged>(
      data: DraggedGroup(id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: groupDragFeedback(context, groupName(id)),
      childWhenDragging: Opacity(opacity: .4, child: item),
      child: slot,
    );
  }
}

/// footer_item: a large icon over its name; the chosen one is marked.
class FooterItem extends StatelessWidget {
  const FooterItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.star = false,
    this.onSecondaryTap,
  });
  final IconData icon;
  final String label;
  final bool on;
  final bool star;
  final VoidCallback onTap;
  final void Function(Offset)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = on ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTap == null ? null : (d) => onSecondaryTap!(d.globalPosition),
      child: Container(
        width: 92,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: on ? scheme.primary.withValues(alpha: .12) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: color),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  if (star)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Icon(Icons.star_rounded, size: 14, color: markColors(context).fresh),
                      ),
                    ),
                  TextSpan(text: label),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: on ? scheme.primary : scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cube (a prism for N groups or origins): the front face and its
/// neighbours, turned in 3D around a vertical axis and flipped vertically
/// around a horizontal axis between groups and origins. A drag turns it
/// continuously and snaps to the nearest face; the wheel (where nothing inside
/// scrolls), a click on a side face, the footer, Left/Right and Ctrl+G turn it
/// a face; the bottom-right option button, Ctrl+Up/Down or a vertical drag
/// flip it between Groups and By origin.
class _CubeOverview extends StatefulWidget {
  const _CubeOverview({
    required this.faces,
    required this.front,
    required this.onFront,
    required this.onFlip,
    required this.face,
    this.direction = 1,
    this.byOrigin = false,
  });
  final List<String> faces;
  final int front;

  /// The way the last key/wheel step went (+1/-1): with two faces both ways
  /// reach the other one, so it decides.
  final int direction;
  final bool byOrigin;
  final void Function(int index) onFront;
  final VoidCallback onFlip;
  final Widget Function(int index, double width, bool isFront) face;

  @override
  State<_CubeOverview> createState() => _CubeOverviewState();
}

class _CubeOverviewState extends State<_CubeOverview> with TickerProviderStateMixin {
  /// The turn, in faces: 0 shows face 0, 1.5 halfway between 1 and 2.
  late final AnimationController page = AnimationController.unbounded(vsync: this, value: widget.front.toDouble());

  /// Vertical tilt/flip around the horizontal axis, in 60° steps (0: level).
  late final AnimationController tilt = AnimationController.unbounded(vsync: this);

  /// Where the turn is heading (unwrapped, like [page]): turns are counted
  /// from here, not from where the cube happens to stand mid-turn.
  late double _target = widget.front.toDouble();
  DateTime _lastWheel = DateTime(0);
  double _faceWidth = 1;
  double _faceHeight = 1;

  int get count => widget.faces.length;

  @override
  void didUpdateWidget(_CubeOverview old) {
    super.didUpdateWidget(old);
    if (widget.byOrigin != old.byOrigin) {
      // Flipped between groups and origins: start on the new front face and
      // tilt it into place around the horizontal axis.
      _target = widget.front.toDouble();
      page.value = _target;
      tilt.value = widget.byOrigin ? -1.0 : 1.0;
      tilt.animateTo(0, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
      return;
    }
    if (count != old.faces.length) {
      // Groups came or went: stand on the front face again, no turn.
      _target = widget.front.toDouble();
      page.value = _target;
      return;
    }
    if (widget.front != _wrap(_target.round())) _turnTo(widget.front, direction: widget.direction);
  }

  @override
  void dispose() {
    page.dispose();
    tilt.dispose();
    super.dispose();
  }

  int _wrap(int i) => count == 0 ? 0 : ((i % count) + count) % count;

  /// The face index, reached the short way round from the target; halfway
  /// round (two faces) in the [direction] asked for.
  void _turnTo(int index, {int direction = 1}) {
    if (count == 0) return;
    var diff = ((index - _target) % count + count) % count; // 0 … count
    if (diff > count / 2 || (diff == count / 2 && direction < 0)) diff -= count;
    _target += diff;
    page.animateTo(_target, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  void _settle() {
    _target = page.value.roundToDouble();
    page.animateTo(_target, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    final index = _wrap(_target.toInt());
    if (index != widget.front) widget.onFront(index);
  }

  void _settleTilt() {
    if (tilt.value.abs() > 0.28) {
      widget.onFlip();
    } else {
      tilt.animateTo(0, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    }
  }

  void _step(int step) {
    if (count <= 1) return;
    final index = _wrap(_target.round() + step);
    _turnTo(index, direction: step);
    widget.onFront(index);
  }

  /// diff of face i from the front, wrapped to [-N/2, N/2].
  double _diff(int i) {
    var d = (i - page.value) % count;
    if (d > count / 2) d -= count;
    return d;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth, height = box.maxHeight;
        _faceWidth = math.min(width * 0.62, 760.0).clamp(160.0, double.infinity);
        final faceHeight = _faceHeight = math.max(80.0, height - 16);
        return Listener(
          // Only what no grid inside scrolls reaches here (the resolver).
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            GestureBinding.instance.pointerSignalResolver.register(event, (event) {
              final e = event as PointerScrollEvent;
              final delta = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
              final now = DateTime.now();
              if (delta == 0 || now.difference(_lastWheel) < const Duration(milliseconds: 250)) return;
              _lastWheel = now;
              _step(delta > 0 ? 1 : -1);
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // One face: nothing to turn horizontally.
            onHorizontalDragStart: count <= 1 ? null : (_) => page.stop(),
            onHorizontalDragUpdate: count <= 1 ? null : (d) => page.value -= d.delta.dx / (_faceWidth * 0.65),
            onHorizontalDragEnd: count <= 1 ? null : (_) => _settle(),
            onHorizontalDragCancel: count <= 1 ? null : _settle,
            onVerticalDragStart: (_) => tilt.stop(),
            onVerticalDragUpdate: (d) => tilt.value = (tilt.value - d.delta.dy / (_faceHeight * 0.55)).clamp(-1.2, 1.2),
            onVerticalDragEnd: (_) => _settleTilt(),
            onVerticalDragCancel: _settleTilt,
            child: AnimatedBuilder(
              animation: Listenable.merge([page, tilt]),
              builder: (context, _) {
                final shown = <(int, double)>[
                  for (var i = 0; i < count; i++)
                    if (_diff(i).abs() <= 1.25 && (count > 1 || i == 0)) (i, _diff(i)),
                ]..sort((a, b) => b.$2.abs().compareTo(a.$2.abs())); // back to front
                // Two faces: the one behind would show on both sides.
                if (count == 2) shown.removeWhere((f) => f.$2.abs() > 1);
                // A regular prism: faces 360°/N apart (60° at most, so a
                // few groups still show their neighbours at a slant).
                final step = 2 * math.pi / math.max(count, 6);
                final radius = (_faceWidth / 2) / math.tan(step / 2);
                final pitch = tilt.value * (math.pi / 3);
                final vRadius = (faceHeight / 2) / math.tan(math.pi / 6);
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    for (final (i, diff) in shown)
                      Positioned(
                        left: (width - _faceWidth) / 2,
                        top: 8,
                        width: _faceWidth,
                        height: faceHeight,
                        child: _placed(i, diff, radius, step, pitch, vRadius),
                      ),
                    Positioned(right: 16, bottom: 12, child: _axisButton(context)),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Bottom-right option button: flips the cube vertically between Groups and
  /// By origin.
  Widget _axisButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(corners(context));
    return Tooltip(
      message: widget.byOrigin ? tr('Groups (Ctrl+G)') : tr('By origin (Ctrl+G)'),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: .92),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        elevation: 2,
        child: InkWell(
          key: const ValueKey('cube-axis-toggle'),
          borderRadius: radius,
          onTap: widget.onFlip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swap_vert, size: 17, color: scheme.primary),
                const SizedBox(width: 5),
                Icon(
                  widget.byOrigin ? Icons.inventory_2_outlined : Icons.folder_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  widget.byOrigin ? tr('Origin') : tr('Groups'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Face i on the prism: [radius] is the apothem, the front face flat at
  /// depth 0, the others turned away and pushed back so their edges meet it
  /// (nothing comes nearer than the front, so perspective never blows up).
  Widget _placed(int i, double diff, double radius, double step, double pitch, double vRadius) {
    final theta = diff * step;
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012) // perspective: farther is smaller
      ..translateByDouble(
        radius * math.sin(theta),
        -vRadius * math.sin(pitch),
        radius * (1 - math.cos(theta)) + vRadius * (1 - math.cos(pitch)),
        1,
      )
      ..rotateX(pitch)
      ..rotateY(-theta);
    final isFront = diff.abs() < 0.15;
    Widget face = widget.face(i, _faceWidth, isFront);
    if (!isFront) {
      // A side face: a click turns it to the front; its inside does nothing.
      face = Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(child: face),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey('cube-side-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _turnTo(i);
                widget.onFront(i);
              },
            ),
          ),
        ],
      );
    }
    return Transform(
      alignment: Alignment.center,
      transform: matrix,
      child: Opacity(opacity: (1.0 - diff.abs() * 0.45 - tilt.value.abs() * 0.25).clamp(0.25, 1.0), child: face),
    );
  }
}
