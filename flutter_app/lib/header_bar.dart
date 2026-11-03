part of 'apps_page.dart';

/// The header's buttons in one card, in the user's order: each one can be
/// dragged to another place; a line shows where it will land (the order is
/// saved in settings.json, `header_order`).
extension HeaderBar on AppsPageState {
  void _set(VoidCallback change) {
    if (mounted) {
      // ignore: invalid_use_of_protected_member
      setState(change);
    }
  }

  /// The saved order, checked as the core checks it.
  List<String> get headerOrder => sizes.headerOrder(settings['header_order']);

  /// A small window: tighter than compact, so the card fits beside the field.
  VisualDensity? get _density =>
      MediaQuery.sizeOf(context).width < 760 ? const VisualDensity(horizontal: -3, vertical: -2) : null;

  /// The button behind an id, or null when it is not there now (● only in
  /// the narrow window, the eye only with hidden apps, plugins on Omarchy).
  Widget? _headerButton(String id) => switch (id) {
    'running' => wide ? null : _runningToggle(),
    'marks' => Builder(
      builder: (context) => IconButton(
        visualDensity: _density,
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
    'hidden' => apps.any((a) => a['hidden'] == true) ? _hiddenToggle() : null,
    'reload' => IconButton(
      visualDensity: _density,
      tooltip: tr('Reload'),
      onPressed: _load,
      icon: const Icon(Icons.refresh),
    ),
    // Always there (Antigravity's review, point 1): a dot while no helper is ready.
    'ask' => IconButton(
      visualDensity: _density,
      tooltip: !aiEnabled
          ? tr('Install apps')
          : askReady
          ? tr('Ask AI')
          : tr('Ask AI (set up a helper first)'),
      onPressed: openAsk,
      icon: Badge(
        isLabelVisible: aiEnabled && !askReady,
        smallSize: 7,
        backgroundColor: markColors(context).update,
        child: Icon(
          askReady ? Icons.auto_awesome : Icons.auto_awesome_outlined,
          color: askReady ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
    ),
    'plugins' => widget.desktop != 'omarchy'
        ? null
        : IconButton(
            visualDensity: _density,
            tooltip: tr('Omarchy plugins'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => PluginsPage(core: widget.core, onHide: widget.onHide)),
            ),
            icon: const Icon(Icons.extension_outlined),
          ),
    'settings' => IconButton(
      visualDensity: _density,
      tooltip: tr('Settings'),
      onPressed: openSettings,
      icon: const Icon(Icons.settings_outlined),
    ),
    _ => null,
  };

  IconData _headerIcon(String id) => switch (id) {
    'running' => Icons.fiber_manual_record_outlined,
    'marks' => Icons.info_outline,
    'hidden' => Icons.visibility_outlined,
    'reload' => Icons.refresh,
    'ask' => Icons.auto_awesome,
    'plugins' => Icons.extension_outlined,
    _ => Icons.settings_outlined,
  };

  /// Where a button dropped at [globalX] lands: before the first shown
  /// button whose middle is right of it.
  int _headerSlot(List<String> shown, double globalX) {
    for (var i = 0; i < shown.length; i++) {
      final box = headerKeys[shown[i]]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final middle = box.localToGlobal(Offset(box.size.width / 2, 0)).dx;
      if (globalX < middle) return i;
    }
    return shown.length;
  }

  /// The new order: [id] before the shown button at [slot] (hidden buttons
  /// keep their places among the rest).
  void _dropHeaderButton(String id, List<String> shown, int slot) {
    final from = shown.indexOf(id);
    // Beside itself (left or right edge of its own place): nothing moves.
    if (slot == from || slot == from + 1) return;
    final order = headerOrder;
    final before = slot < shown.length ? shown[slot] : null;
    order.remove(id);
    final at = before == null ? order.length : order.indexOf(before);
    order.insert(at < 0 ? order.length : at, id);
    unawaited(_saveSetting('header_order', order));
  }

  Widget _headerCard() {
    final scheme = Theme.of(context).colorScheme;
    final shown = [
      for (final id in headerOrder)
        if (_headerButton(id) != null) id,
    ];
    Widget line() => Container(
      key: const ValueKey('header-drop-line'),
      width: 3,
      height: wide ? 30 : 24,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(2)),
    );
    final children = <Widget>[];
    for (var i = 0; i < shown.length; i++) {
      final id = shown[i];
      if (headerDropAt == i) children.add(line());
      final button = KeyedSubtree(key: headerKeys.putIfAbsent(id, GlobalKey.new), child: _headerButton(id)!);
      children.add(
        Draggable<String>(
          data: 'header:$id',
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: scheme.secondaryContainer,
            shape: const CircleBorder(),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(_headerIcon(id), color: scheme.onSecondaryContainer),
            ),
          ),
          childWhenDragging: Opacity(opacity: .3, child: button),
          onDragEnd: (_) => _set(() => headerDropAt = null),
          child: button,
        ),
      );
    }
    if (headerDropAt == shown.length) children.add(line());
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data.startsWith('header:'),
      onMove: (d) {
        final slot = _headerSlot(shown, d.offset.dx);
        final from = shown.indexOf(d.data.substring('header:'.length));
        // No line where a drop would change nothing.
        final shownSlot = slot == from || slot == from + 1 ? null : slot;
        if (shownSlot != headerDropAt) _set(() => headerDropAt = shownSlot);
      },
      onLeave: (_) => _set(() => headerDropAt = null),
      onAcceptWithDetails: (d) {
        final slot = _headerSlot(shown, d.offset.dx);
        _set(() => headerDropAt = null);
        _dropHeaderButton(d.data.substring('header:'.length), shown, slot);
      },
      builder: (context, candidates, _) => Tooltip(
        message: tr('Drag a button to move it'),
        waitDuration: const Duration(seconds: 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(corners(context).clamp(4, 14)),
            border: Border.all(color: candidates.isNotEmpty ? scheme.primary : scheme.outlineVariant),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}
