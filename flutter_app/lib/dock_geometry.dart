/// Where the dock's parts go on its layer surface (dock.py's apply_layout and
/// fit_band in numbers). The surface is anchored to the edge and along its
/// whole length; only the dock itself takes the pointer (the input region),
/// the rest of it is transparent and lets clicks through.
///
/// "Along" runs with the edge, "across" away from it (0 at the screen edge).
library;

import 'dart:math' as math;
import 'dart:ui';

const dockGap = 6; // A compact dock floats this far from the edge.
const dockStrip = 2; // The hidden dock's hover strip.
const dockMarker = 4; // The drop marker's thickness.

/// Room beyond the dock for an icon's name (above it, or beside it on a side edge).
int tipRoom(bool vertical) => vertical ? 220 : 34;

/// Room beyond the dock while a menu is open.
int menuRoom(bool vertical) => vertical ? 260 : 380;

enum SlotKind { manager, separator, placeholder, app }

/// One thing in the dock's row, in order.
final class DockSlot {
  const DockSlot(this.kind, [this.key]);
  final SlotKind kind;
  final String? key;
  bool get isItem => kind == SlotKind.manager || kind == SlotKind.app;
}

final class DockGeometry {
  DockGeometry({
    required this.edge,
    required Map settings,
    required Map sizes,
  }) : full = settings['dock_full_width'] == true,
       autohide = settings['dock_autohide'] == true,
       align = '${settings['dock_align'] ?? 'center'}',
       icon = (settings['dock_icon_size'] as num? ?? 32).toInt(),
       spacing = (settings['dock_spacing'] as num? ?? 6).toInt(),
       band = (sizes['band'] as num? ?? 48).toInt(),
       item = (sizes['item'] as num? ?? 46).toInt(),
       room = (sizes['room'] as num? ?? 48).toInt(),
       grow = (sizes['grow'] as num? ?? 0).toInt();

  final String edge, align;
  final bool full, autohide;
  final int icon, spacing, band, item, room, grow;

  bool get vertical => edge == 'left' || edge == 'right';
  int get gap => full ? 0 : dockGap;

  /// A slot's length along the edge: an icon button (icon + 2 × 4 padding),
  /// a separator (1 + 2 × 4 margin), the placeholder (icon + 2 × 4 margin).
  int slotLength(DockSlot slot) => slot.kind == SlotKind.separator ? 9 : icon + 8;

  /// The row's natural length (fit_band's measure).
  int contentLength(List<DockSlot> slots) =>
      slots.fold<int>(0, (sum, s) => sum + slotLength(s)) + spacing * math.max(0, slots.length - 1);

  /// The surface's thickness: the dock, its room and the room for names, or
  /// for a menu. A hidden dock keeps it (resizing the surface on every
  /// hover raced with Flutter's frames); only its input shrinks to the strip.
  int thickness({bool menu = false}) => gap + room + (menu ? menuRoom(vertical) : tipRoom(vertical));

  /// The hidden dock's hover strip on the screen edge.
  Rect stripRect(Size size) => place(size, 0, 0, alongLength(size), dockStrip.toDouble());

  /// Windows keep clear of the band; none with auto-hide.
  int get exclusive => autohide ? 0 : gap + band;

  /// The band's start and length along the edge on a surface [length] long.
  (double, double) bandAlong(double length, int content) {
    if (full) return (0, length);
    final bandLength = (content + 16).toDouble();
    return ((length - bandLength) / 2, bandLength);
  }

  /// Where the row of icons starts along the edge.
  double itemsStart(double length, int content) {
    if (!full) return (length - content) / 2;
    return switch (align) {
      'start' => 8,
      'end' => length - content - 8,
      _ => (length - content) / 2,
    };
  }

  /// The icons' distance from the edge: on the band, centred in it when they fit.
  int get itemsAcross => gap + math.max(0, (band - item) ~/ 2);

  /// Each slot's start along the edge.
  List<double> slotStarts(double length, List<DockSlot> slots) {
    var at = itemsStart(length, contentLength(slots));
    final out = <double>[];
    for (final s in slots) {
      out.add(at);
      at += slotLength(s) + spacing;
    }
    return out;
  }

  /// A rectangle given along/across on a surface of [size] (across 0 at the screen edge).
  Rect place(Size size, double along, double across, double alongLength, double acrossLength) => switch (edge) {
    'top' => Rect.fromLTWH(along, across, alongLength, acrossLength),
    'left' => Rect.fromLTWH(across, along, acrossLength, alongLength),
    'right' => Rect.fromLTWH(size.width - across - acrossLength, along, acrossLength, alongLength),
    _ => Rect.fromLTWH(along, size.height - across - acrossLength, alongLength, acrossLength),
  };

  double alongLength(Size size) => vertical ? size.height : size.width;

  /// The band (the dock's background).
  Rect bandRect(Size size, List<DockSlot> slots) {
    final (start, length) = bandAlong(alongLength(size), contentLength(slots));
    return place(size, start, gap.toDouble(), length, band.toDouble());
  }

  /// What takes the pointer while the dock is shown: the band with room for
  /// growing icons, from the screen edge to the top of the room.
  Rect inputRect(Size size, List<DockSlot> slots) {
    final (start, length) = bandAlong(alongLength(size), contentLength(slots));
    final half = full ? 0.0 : (grow ~/ 2).toDouble();
    final from = math.max(0.0, start - half);
    final to = math.min(alongLength(size), start + length + half);
    return place(size, from, 0, to - from, (gap + room).toDouble());
  }

  /// The slot's rectangle (its button, across the item's thickness).
  Rect slotRect(Size size, List<DockSlot> slots, int index) {
    final starts = slotStarts(alongLength(size), slots);
    return place(size, starts[index], itemsAcross.toDouble(), slotLength(slots[index]).toDouble(), item.toDouble());
  }

  /// The drop marker in the gap before (or after) the slot.
  Rect markerRect(Size size, List<DockSlot> slots, int index, {required bool after}) {
    final starts = slotStarts(alongLength(size), slots);
    final edgeAt = starts[index] + (after ? slotLength(slots[index]) : 0);
    final offset = after ? spacing / 2 : -spacing / 2;
    return place(size, math.max(0, edgeAt + offset - dockMarker / 2), itemsAcross + 2.0, dockMarker.toDouble(),
        item - 4.0);
  }

  /// Which neighbours grow halfway: the items right before and after [index].
  Set<int> neighbours(List<DockSlot> slots, int index) => {
    for (final i in [index - 1, index + 1])
      if (i >= 0 && i < slots.length && slots[i].isItem) i,
  };
}

/// Slots for the dock's items: App Manager's button, a separator, the
/// placeholder while nothing is pinned, the pinned apps, a separator, the
/// running ones (dock.refresh).
List<DockSlot> dockSlots(List<Map> items) {
  final pinned = [for (final i in items) if (i['pinned'] == true) i];
  final running = [for (final i in items) if (i['pinned'] != true) i];
  return [
    const DockSlot(SlotKind.manager),
    const DockSlot(SlotKind.separator),
    if (pinned.isEmpty) ...[
      const DockSlot(SlotKind.placeholder),
      if (items.isNotEmpty) const DockSlot(SlotKind.separator),
    ],
    for (final i in pinned) DockSlot(SlotKind.app, '${i['key']}'),
    if (pinned.isNotEmpty && running.isNotEmpty) const DockSlot(SlotKind.separator),
    for (final i in running) DockSlot(SlotKind.app, '${i['key']}'),
  ];
}
