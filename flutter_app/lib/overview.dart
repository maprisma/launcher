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

  Widget _folders(int cardWidth, int height) {
    final folders = [
      for (final (id, keys) in overviewSections)
        if (id != 'all' && (keys.isNotEmpty || (id != '_running' && id != 'other'))) (id, keys),
    ];
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

  // --- the footer --------------------------------------------------------------

  /// fill_filter_bar: All and the groups (each a place to drop an entry or
  /// a group), New group last; the layouts on the right.
  Widget _footerBar() {
    final scheme = Theme.of(context).colorScheme;
    final wanted = wantedFilter;
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
                  for (final (id, keys) in overviewSections) _footerChip(id, keys.length, id == wanted),
                  _newGroupButton(compact: true),
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
                    },
                    icon: Icon(switch (layout) {
                      WideLayout.folders => Icons.folder_copy_outlined,
                      WideLayout.cards => Icons.view_agenda_outlined,
                      WideLayout.icons => Icons.apps,
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
