# App Manager: one Flutter app for every Linux desktop (plan, 2026-11-03)

## Decisions (Uwe, 2026-11-03)

- **Base:** gnome-launcher (`/mnt/Data/Projects/gnome-launcher`, newest App Manager line: icons layout,
  footer groups, COSMIC shortcuts). Built like Maprisma.
- **Name:** App Manager (the marketplace name). The Omarchy plugin becomes its thin launcher.
- **Core:** Dart only. One binary, no Python on the target system. The Python code is kept here as the
  **reference implementation and test oracle** (`reference/`), as in Maprisma.
- **Desktops:** Omarchy (Hyprland), GNOME and COSMIC, each with its own theming; a generic XDG fallback.
- **Plugin support = both:** (a) desktop hooks (Omarchy bar plugin, GNOME top-bar extension, COSMIC
  applet), each only opening/toggling the app; (b) signed, data-only add-ons for the app itself.
- **Old apps:** the Omarchy plugin App Manager 2.4.1 and gnome-launcher are **frozen, fixes only** until
  this app replaces them.
- Nothing is pushed, released or sent to the marketplace without Uwe's OK.

## Layout (mirrors Maprisma)

```
appmanager/
  packages/appmanager_core/   Dart core: scan, groups, shortcuts, icons, updates, new apps, settings
    protocol/routes.json      the one GUI↔core contract (generated docs/protocol.md, typed client)
  flutter_app/                UI: list, groups, folders, icons, cards, key map, details, settings
  reference/                  gnome-launcher Python + Omarchy plugin desktop_omarchy parts, frozen at a commit
  addons/                     built-in add-on data; format in docs/addons.md
  hooks/omarchy | gnome | cosmic   the thin desktop launchers
  packaging/                  AppImage, AUR appmanager-bin, tarball (copied from Maprisma's scripts)
```

App ID `io.github.ubruckhaus.AppManager`, config `~/.config/appmanager/`.
First start **copies** (never moves) settings, groups, hidden lists, icons and seen.json from
`~/.config/applauncher/` (Omarchy) or `~/.config/gnome-launcher/`, whichever is newer, with a report.

## Desktop adapters (built into the Dart core)

One interface, picked at start (`XDG_CURRENT_DESKTOP`, `HYPRLAND_INSTANCE_SIGNATURE`, override in settings):

| Function | Omarchy | GNOME | COSMIC | Generic |
|---|---|---|---|---|
| Theme colours, corners | theme files + looknfeel.lua (corners.py) | gsettings accent/colour-scheme, libadwaita | `~/.config/cosmic/com.system76.CosmicTheme.*` | light/dark from portal |
| Global shortcuts + key map owners | Hyprland Lua binds (`hl.bind`), Omarchy defaults | custom-keybindings gsettings, take/restore GNOME keys | COSMIC shortcut file (keep user entries, 3940773) | none (read-only) |
| Launch / focus | `omarchy-launch-or-focus`, `hl.dsp.focus` | Gio launch, `%k` filled | Gio launch | Gio launch |
| Pin / favourites | dock (later, see open points) | Dash favourites | COSMIC dock favourites | — |
| Terminal, system update | Omarchy terminal, omarchy-update | default terminal, Software | cosmic-term, cosmic-store | `$TERMINAL`/xdg-terminal-exec |
| Window behaviour | float + centre window rule; toggle via single-instance socket | normal window, toggle | normal window, toggle | normal window |

Low-level calls (bounded reads, `O_NOFOLLOW`, process start) reuse Maprisma's `posix_ffi.dart` approach.
A new desktop needs an app update (adapters have code); add-ons only carry data.

## Add-ons (data only, signed, Uwe signs)

Same model as Maprisma (`docs/addons.md` there): TOML + assets, Ed25519, catalog, install/remove with preview.
Planned kinds: **icon sources** (index URL, format, licence), **app sources/origins** (paths and rules that
sort apps by origin, e.g. a distro's web-app folder), **group presets**, **themes/translations**.
No add-on runs code.

## Desktop hooks

- **Omarchy:** new version of `ubruckhaus.simple-launcher-for-fools` = a small bar widget that starts or
  toggles `appmanager`, offers to install it when missing (AUR/AppImage). Marketplace update only at the end.
- **GNOME:** gnome-launcher's `shell-extension/launcher-button@ubruckhaus.github.io`, pointed at the new app.
- **COSMIC:** a small applet (Rust, libcosmic) or a panel launcher entry; decided in milestone 6.

## Milestones (each ends with its tests green and a local commit)

0. **Base frozen.** gnome-launcher working tree (icons layout/footer, 219 tests OK on 2026-11-03) committed
   there; `reference/` copied at that commit; Omarchy-only parts (desktop_omarchy, dock) copied from 2.4.1 6389778.
1. **Skeleton.** Repo, Dart core package, Flutter app, routes.json + generator, CI-less local test script,
   GNOME adapter read-only (theme). Window opens themed on GNOME and Omarchy.
2. **Core port, read side.** Desktop-file scan (bounded), origins, AppImages, CLI tools, groups, hidden,
   new-app stars, details; each module tested against the Python oracle on fixture homes.
3. **UI parity.** List, groups, by-origin, folders, icons, cards, footer, filter, drag & drop, details,
   settings, 8 languages (i18n from omarchy-plugin-i18n).
4. **Write side per desktop.** Shortcuts + key map (Omarchy, GNOME, COSMIC), pin, Change icon (bounded curl
   equivalent in Dart), updates, Quit rules from 2.4.1.
5. **Add-ons.** Format, signing, catalog, built-in icon sources moved to add-ons.
6. **Packaging + hooks.** AppImage, AUR, tarball; Omarchy bar plugin, GNOME extension, COSMIC applet;
   tested in VMs (Omarchy edge VM, GNOME, COSMIC), never quattro on Uwe's desktop.
7. **Replace.** Settings migration tested on Uwe's real configs (copies), Codex review until CLEAN, then on
   Uwe's OK: push, marketplace [Verify] for the thin plugin.

## Open points

- **Dock** (Omarchy 2.x dock.py is a layer-shell window): Flutter has no layer-shell out of the box. Options:
  keep a separate small dock, use a layer-shell embedder, or drop it. Decide before milestone 4.
- Omarchy popup feel: a floating window via window rules instead of a layer-shell popup; check focus/Esc.
- Which GNOME/COSMIC VMs exist; create if missing.

## Progress

- **2026-11-03 — milestone 0 done:** gnome-launcher e311759 frozen; `reference/` holds it and the Omarchy
  plugin 2.4.1 6389778; `tools/oracle.py` runs the reference for tests.
- **2026-11-03 — milestone 1 done, milestone 2 started:**
  - Core: scan (desktop entries, AppImages, CLI tools) equal to Python on this machine (111 apps, C/de/fr)
    and on fixture homes; desktop adapters (Omarchy, GNOME, COSMIC, generic) for colours, corners, icon
    theme; icon lookup; launching without Gio or a shell (Omarchy via uwsm-app); routes in
    `docs/protocol.md`.
  - App: Maprisma's runner (single instance, `--toggle`, `hide`), theme from the desktop's palette, list
    and icon views, type-to-filter, Enter/arrows/Esc, right-click menu with the entry's actions, details.
  - Screenshots offscreen: `SHOTS=<dir> flutter test test/shots_test.dart` (no Xvfb here; Broadway has no
    GL for Flutter). Caught a tile overflow already.
- **2026-11-03 — groups and origins:** core ports groups.py (equal on an edit sequence) and the origin
  sections of both references (Omarchy: defaults/omarchy/other; else defaults/system/flatpak/user — equal on
  this machine); hidden entries; settings; first start copies ~/.config/applauncher or gnome-launcher
  (originals kept). App: A–Z / Groups / By origin (Ctrl+G, saved), foldable headings with ⋮ (rename, move,
  delete, new group), Move to group…, Hide from list, Show hidden. Widget test on a fixture home.
- **2026-11-03 — drag and drop (groups view):** entries onto a heading (into it), onto an entry (before/after
  it, accent bar), onto New group (starts one with it); group headings onto each other (reorder). In-window
  Flutter drags, no compositor DnD (as gnome-launcher's pointer moves, which COSMIC never started).
- **Next (parity with gnome-launcher, in this order):** folders/cards/footer layouts, settings page (sizes, corners, layouts, language) + 8 languages, hidden
  entries and marks (new ★, updates), running state, shortcuts + key map per desktop (shortcuts.py),
  Change icon (icons.py), updates (updates.py), admin launch.
