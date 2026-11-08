# Maprisma Launcher on KDE Plasma

Added 2026-11-08 (Plasma 6.8, Wayland), the same way as Maprisma Theme's KDE support
(/mnt/Data/Projects/maprisma-theme/docs/multi-desktop.md).

- **Detection**: `XDG_CURRENT_DESKTOP` contains `KDE` → `KdeDesktop` (`MAPRISMA_LAUNCHER_DESKTOP=kde`
  forces it).
- **Look**: kdeglobals — window background/text, the accent (Plasma's `AccentColor`, else the focus
  decoration, else the selection: Maprisma's schemes mix the selection, which is too dark for text),
  the view's negative/neutral/positive for red/yellow/green; icons from `[Icons] Theme` (default
  breeze); Breeze's 8 px corners.
- **System update**: Discover's update page (`plasma-discover --mode update`) when installed, else the
  terminal update as on other desktops.
- **Windows** (Running card, window list, focus, close): KWin scripts through `kwin_bridge.dart`, copied
  from Maprisma Theme's core; `app_id` is the window's desktop file name (else its class), so matching
  is the COSMIC one (`toplevelWindowsOf`, `cosmicStates`). COSMIC and KDE share `ToplevelWindows`.
  D-Bus only through the Session's `DBUS_SESSION_BUS_ADDRESS`: tests never reach the real session.
- **App shortcuts**: `KdeSettings` (shortcuts_kde.dart, Codex) implements `KeySettings`, so the GNOME
  backend logic (take/give back, custom entries) runs unchanged: KDE's own shortcuts are kglobalaccel's
  actions; ours are hidden desktop files `maprisma-launcher-N.desktop` that kglobalaccel launches itself.
- **Installer**: the app entry's `Exec` carries the quoted full path (Plasma's PATH has no
  ~/.local/bin), and a hidden `com.maprisma.Launcher.Toggle.desktop` shows/hides the window for panel
  icons.
- Not on KDE: the dock and popup placement (Omarchy/Hyprland only), as on COSMIC.
