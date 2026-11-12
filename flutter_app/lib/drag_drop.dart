import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'theme.dart';

/// What is being moved inside the window: an entry (by key) or a group.
sealed class Dragged {
  const Dragged();
}

final class DraggedApp extends Dragged {
  const DraggedApp(this.key);
  final String key;
}

final class DraggedGroup extends Dragged {
  const DraggedGroup(this.id);
  final String id;
}

/// The icon that follows the pointer, beside it so the target stays in view.
Widget appDragFeedback(String? iconFile) => Transform.translate(
  offset: const Offset(8, 8),
  child: Material(type: MaterialType.transparency, child: AppIcon(iconFile, size: 40)),
);

Widget groupDragFeedback(BuildContext context, String name) {
  final scheme = Theme.of(context).colorScheme;
  return Transform.translate(
    offset: const Offset(8, 8),
    child: Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(cornerSizes(context).control),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    ),
  );
}

/// A place something can be dropped on. A sided drop lands before or after
/// the slot (the pointer's half, an accent bar shows where); an unsided one
/// goes into it (the slot lights up).
class DropSlot extends StatefulWidget {
  const DropSlot({
    super.key,
    required this.accepts,
    required this.onDrop,
    required this.child,
    this.sided = _never,
    this.horizontal = false,
  });
  final bool Function(Dragged) accepts;
  final bool Function(Dragged) sided;
  final void Function(Dragged, bool after) onDrop;
  final bool horizontal;
  final Widget child;
  static bool _never(Dragged _) => false;
  @override
  State<DropSlot> createState() => _DropSlotState();
}

class _DropSlotState extends State<DropSlot> {
  bool? _after; // null: nothing over it; true/false: the side
  bool _into = false;

  bool _afterAt(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final local = box.globalToLocal(global);
    return widget.horizontal ? local.dx > box.size.width / 2 : local.dy > box.size.height / 2;
  }

  void _clear() => setState(() {
    _after = null;
    _into = false;
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return DragTarget<Dragged>(
      onWillAcceptWithDetails: (d) => widget.accepts(d.data),
      onMove: (d) {
        if (!widget.accepts(d.data)) return;
        final sided = widget.sided(d.data);
        final after = sided ? _afterAt(d.offset) : false;
        if (_into != !sided || _after != after) {
          setState(() {
            _into = !sided;
            _after = after;
          });
        }
      },
      onLeave: (_) => _clear(),
      onAcceptWithDetails: (d) {
        final after = widget.sided(d.data) && _afterAt(d.offset);
        _clear();
        widget.onDrop(d.data, after);
      },
      builder: (context, _, _) {
        final bar = _after != null && !_into;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: _into ? accent.withValues(alpha: .18) : null,
                borderRadius: BorderRadius.circular(cornerSizes(context).control),
              ),
              child: widget.child,
            ),
            if (bar)
              widget.horizontal
                  ? Positioned(
                      top: 4,
                      bottom: 4,
                      left: _after! ? null : -1.5,
                      right: _after! ? -1.5 : null,
                      child: Container(width: 3, color: accent),
                    )
                  : Positioned(
                      left: 4,
                      right: 4,
                      top: _after! ? null : -1.5,
                      bottom: _after! ? -1.5 : null,
                      child: Container(height: 3, color: accent),
                    ),
          ],
        );
      },
    );
  }
}
