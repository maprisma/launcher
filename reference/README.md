# Reference implementations (frozen, read-only)

The Dart core must behave like these. They are the test oracle (tools/oracle.py), never shipped.

- `gnome-launcher/` — gnome-launcher at e311759 (2026-11-03), the feature base.
- `omarchy-plugin/` — Omarchy plugin App Manager 2.4.1 at 6389778, for the Omarchy adapter
  (desktop_omarchy.py, Hyprland shortcuts, dock).

Fixes to the old apps go to their own repos; copy them here only when the Dart port needs them.
