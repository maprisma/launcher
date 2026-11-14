# Maprisma Launcher (was: App Manager): one Flutter app for every Linux desktop (plan, 2026-11-03)

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

- **Dock:** decided and done 2026-11-03 (below): the same binary as `maprisma-launcher --dock`, GTK3
  gtk-layer-shell loaded at run time.
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
- **2026-11-03 — wide window:** as wide as two cards, the list turns into the overview (launcher.py's
  grid_columns), Folders / Cards / Icons (saved), folders that fill the page (folder_fit and friends ported,
  equal to Python over 288 window sizes), open a folder by clicking it (Esc back), the group bar at the bottom
  (All, groups, New group; wheel scrolls it; drop entries or groups on it), Ctrl+G next group.
  Not yet: Running group, marks on icons (updates, new ★), the filter field's × setting, keyboard focus on
  folders, footer ‹ › arrows.
- **2026-11-03 — settings page and 8 languages:** gear in the header; language (System + 8), layouts small /
  wide, layouts in the footer, view buttons when small (off by default, as the reference), corners, filter field
  (off: typing still filters, the header shows it), four icon sizes, Reset to defaults; all apply at once.
  Translations: `tools/i18n.py` builds `flutter_app/assets/translations/` from the Omarchy plugin's tables plus
  `i18n/extra.json` (App Manager's own texts); a test fails when a text lacks a language or the files are stale.
  Group names from the core stay English in the name check (a German "Büro" could be added once more).
- **2026-11-03 — marks:** new ★ (newapps.py: seen.json, 7 days or until opened), running dot (process scan every
  3 s in the core's isolate), Running folder/chip (wide) and ● running-first (narrow), update dot + Update (Flatpak,
  alone) / Update system… (packages: the desktop's updater; never one package alone on Arch), from updates.py
  (pacman -Qo, checkupdates, yay/paru -Qua, flatpak) at most every 30 minutes; uninstall_plan ported (the
  Flatpak id). Equal to the references (marks oracle incl. all 111 real apps' process names and plans). Live: VS Code
  update found on this machine. Not yet: the legend of the marks, Open windows vs background (Hyprland clients).
- **2026-11-03 — F12 screenshots (as Maprisma):** F12 saves a picture of the window (dialogs included) to
  ~/Pictures/AppManager or the folder from Settings, then asks for an optional note (.txt next to it).
  Settings: "F12 saves a screenshot" (on by default), "Screenshots go to" (folder chooser, Default).
  Translations also come from Maprisma's tables now.
- **2026-11-03 — Ask AI step 1 begun (docs/proposals/ask-ai.md):** names and descriptions in the desktop's
  language (Name/Comment/GenericName; `localized: false` keeps the reference's for the oracle tests);
  package facts (facts.dart: one `pacman -Qo` for all, pacman's local database read directly, one
  `flatpak list`, AppImage file sizes) equal to details.app_facts for every app here; cards show size · source
  and the package description when the entry has none, only for the app's own package (web apps and CLI tools
  show their kind); Details lists package, size, website. Found: `pacman -Qo` exits with the number of misses,
  so the reference's update check (ok 0/1) finds nothing once two /usr desktop files have no owner; fixed here.
- **2026-11-03 — step 1 continued:** packages.dart: managers detected (pacman, AUR helper, Flatpak, Snap, apt,
  dnf, zypper), Settings › Package managers (AUR off by default), search over the enabled ones (no shell;
  pacman's regex escaped), Install apps page with a review showing the exact command (+ AUR warning), installs
  in a terminal with the package as "$1" and only for packages the last search returned; Uninstall… extended
  to apt/dnf/zypper (dpkg -S, rpm -qf) and Snap, warnings for default apps and Omarchy base packages, own
  entries to the freedesktop trash. Live: `gimp` found, plan `sudo pacman -S -- gimp`. Not run for real
  (would install/remove); apt/dnf/zypper/snap parsers only on sample output.
  Step 1 left: Details page (now a dialog), the AUR PKGBUILD view (the helper shows it in the terminal).
- **2026-11-03 — Ask AI step 2 built:** ask_ai.dart: helpers Claude Code (no tools, Maprisma's rewrite argv),
  Codex (read-only sandbox), Antigravity (plan mode + sandbox: read-only, can read files); detection without
  tokens (program + credential file/env, never read); prompts with Maprisma's isolation; call 1 → one action
  (search, remove, update, update_system, explain, clarify, redirect), checked against installed ids; search →
  real results from the enabled managers (official first) → call 2 picks ≤3, every pick must be a found
  package; the picks go through the same install review. Runs logged in the plugins' runs.json under flock.
  Ask page: helper picker with cost note, starter chips, onboarding (sign in in terminal, Install apps without
  AI); header ✦ always visible, dot while no helper. Tested with a fake helper (no tokens). **Not run with a
  real helper yet: needs Uwe's click.** Not yet: action rules (Maprisma 019), online API keys, local helper.
- **Next (parity with gnome-launcher, in this order):** marks (new ★, updates), running state, shortcuts + key map per desktop (shortcuts.py),
  Change icon (icons.py), updates (updates.py), admin launch.

- **2026-11-03 — renamed to Maprisma Launcher (Uwe):** app ID `com.maprisma.Launcher`,
  binary `maprisma-launcher`, Dart packages `maprisma_launcher` / `maprisma_launcher_core`, folders
  `~/.config/maprisma-launcher`, `~/.cache/maprisma-launcher`, `~/Pictures/MaprismaLauncher`, run log plugin
  `maprisma-launcher`, env `MAPRISMA_LAUNCHER_DESKTOP`, repo folder `/mnt/Data/Projects/maprisma-launcher`.
  The first start still copies the old App Manager's files (~/.config/applauncher or gnome-launcher).
  Marketplace: a new plugin, see docs/publishing.md.
- **2026-11-03 — global shortcuts + key map (milestone 4, first part):** shortcuts.dart / shortcuts_hypr.dart /
  shortcut_service.dart port both references' shortcuts.py. GNOME: custom keybindings through the `gsettings`
  program (argv, bounded) at `…/custom-keybindings/maprisma-launcher-N/`, GNOME keys taken and given back
  ("applied"), the Dash's Super + 1…9. COSMIC: its `custom` shortcut file, entries tagged " (Maprisma Launcher)",
  every other entry kept as written, one atomic write, never a file that cannot be read back. Omarchy: the Lua
  module `~/.config/hypr/maprisma-launcher-shortcuts.lua`, required last from hyprland.lua (backup once),
  `hyprctl reload`, files restored on a new configuration error. Generic: read-only. App: Shortcut… in the menu,
  a page with the current shortcuts (change, remove, turn off/on), Opens (app or one of its actions), modifier
  chips, the default modifiers, a key map coloured free / yours / desktop default, Assign / Move here / Rebind,
  keys pressed with modifiers; Esc, Enter. Oracle (`oracle.py shortcuts`) equal on combos, states, COSMIC's file
  over three saves, GNOME's bindings and saves on a fake GSettings, Hyprland's binds, files, bindings and
  module; the routes tested with a fake gsettings, a COSMIC folder and a fake hyprctl in a temporary HOME.
  Not copied at first start: the old apps' shortcuts.json (their keys live in their own Lua module, custom
  paths or "(Launcher)" entries, which keep working and show on the key map as the user's own; copying would
  bind each key twice). Not yet: two-step shortcuts in the UI (kept and rendered when in the state), key
  capture while the page is open (Hyprland submap / GNOME inhibit), list chips, removing dead hand-written
  binds, the key colours' hue fix (key_colors.py). Not run on a live desktop yet.
- **2026-11-03 — Omarchy features (Uwe chose: plugins page, Open as administrator, dock, tray Quit):**
  popup mode (window_mode auto|popup|window: floated, centred, no title bar, closes on Esc/blur; VM-tested),
  windows (Switch to window, Open in floating window, Open on workspace › through Hyprland Lua dispatch,
  running states active/background), Omarchy uninstall (omarchy-remove-launcher-entry by kind), the plugins
  page (open, bar in/out, update, uninstall with the git-loss warning, via Omarchy's own commands; oracle
  `plugins`), Open as administrator (opt-in per login session, polkit password, `oracle.py admin`; the X
  access grant through libX11 not run live), Quit (the app's own tray Quit entry over busctl; `oracle.py
  tray`, a fake busctl, read-only live probe: NordVPN and Screen Narrator found, nothing clicked).
  docs/protocol.md lists every route. Dock: in progress (gtk-layer-shell for GTK3 via dlopen, VM only).
- **2026-11-03 — the dock (Omarchy only, branch task/dock):** the Omarchy App Manager's dock ported.
  Core `dock.dart` = dock_core.py (settings, edge, sizes, dock_rect, inside, indicator colour, split_events,
  pinned operations, dropped_id, items, bar_position), equal to it in `oracle.py dock`; routes `dock.*`
  (docs/protocol.md) with a fake hyprctl in `dock_service_test.dart`. The dock is a process of its own:
  `maprisma-launcher --dock`, application id `com.maprisma.Launcher.Dock` (a second start makes it re-read its
  settings; switched off it ends). The runner loads `libgtk-layer-shell.so.0` (GTK3, package gtk-layer-shell)
  with dlopen and refuses with a message (exit 3) without it; Settings › Dock then names the package, and
  off Omarchy says GNOME and COSMIC have their own docks. The surface is anchored along the whole edge and
  transparent; Flutter draws the band and sets the input region (only the dock, or the 2 px strip while
  auto-hidden, takes the pointer), the exclusive zone (gap + band) and the thickness (more while a menu is
  open). Started with the shell by the plugin's bar widget (`maprisma-launcher-toggle --dock`, as the old
  widget started dock.py) and by the app on Omarchy when the dock is on. Hyprland's socket2 with the line
  limit, a 4 s poll, the settings files followed every second; only windows Hyprland just listed are focused
  or closed. VM (tools/vm-dock, edge image, 1280×800): refused without the library (exit 3, no layer);
  installed: bottom with the bar at the top, reserved [0, 26, 0, 54], no overlap; name on hover; click
  launches Files, then focuses it; menu; Unpin; Pin to dock on running Chromium; drag reorder; Close;
  auto-hide (hover over the hidden area does not reveal it, the edge does, it hides again); top asked with
  the bar at the top → bottom; left (reserved 54 left); a second start and the toggle keep one dock; off
  ends it. Screenshots in docs/shots/dock-*.png. Different from dock.py: no drop from the app (no
  compositor drag and drop in the Flutter app; "Pin to dock" in its menu instead), no "popup-open" message
  (the app is a normal floating window, the pointer reaches the edge), no hang watchdog, names and menus
  drawn by Flutter inside the surface (it grows while a menu is open).
- **2026-11-03 — fourth wide layout "Cube" (`cube`):** one face per group (the folder layout's groups) on a
  regular prism, faces 360°/N apart (60° at most). The front face is flat, the others turned away and pushed back
  so their edges meet it: nothing comes nearer than the front, so perspective never blows up. (The proposed
  formula moved side faces toward the viewer at 82° and made them 2,800 px wide.) Turned by a drag (snaps to
  the nearest face), the wheel where no grid inside scrolls, a click on a side face, the footer chips (All = the
  first face; the front face's chip is marked), Left/Right and Ctrl+G (no stop on All). Faces: name, count,
  ⋮ group menu, icon tiles (start, menu, drag), a drop target for apps. Filtering shows the normal grid.
  Widget test + offscreen shot (`SHOTS=… flutter test test/shots_test.dart --plain-name cube`).
- **2026-11-05 — installed-app updates:** Update checks already covered pacman/AUR and Flatpak. They now
  read standard `.upd_info` from user AppImages with `readelf`, query the named GitHub release and matching
  AppImage asset, and require the published SHA-256 before offering an update. This works for any AppImage
  with supported `gh-releases-zsync` metadata, with no publisher allowlist. Ask AI receives those update
  facts; broad update questions use the core's checked list so a helper cannot say none when updates were
  found. The app menu and Ask AI can install an AppImage update with a backup of the old binary, and cards
  show installed package, Flatpak and AppImage versions. AppImages without update information remain unknown.

- **2026-11-08 — COSMIC windows:** offline Rust toplevel helper, desktop-id /
  StartupWMClass / executable matching, window lists, focus and close through the
  existing routes. Running sections and the footer filter use open windows on
  COSMIC and Omarchy; background process marks remain in groups. GNOME/generic
  keep process matching. The release bundles the helper beside the app.

- **2026-11-13 — Shared AI helper:** Ask AI offers every installed agent of Maprisma's helpers catalog
  (`/usr/lib/maprisma/data/helpers.json` when at least as new, else the shipped copy from
  `tools/gen-helpers`), found on PATH, in ~/.local/bin, ~/.npm-global/bin or through mise. Claude Code, Codex,
  Antigravity, pi and Hermes keep the Launcher's stricter setups; other entries run by the catalog's argv,
  unverified ones say "(untested)". The helper is the shared choice of all Maprisma apps
  (`maprisma-ai/settings.json`, key `helper`), set from Ask AI's drop-down, Settings › Apps & AI and Maprisma
  Manager › AI; the old `ask_helper` is read until that file exists.

- **2026-11-13 — GitHub releases and web discovery (ported from `fix/github-release-discovery`, 2026-11-05):**
  Ask AI preserves explicit `app from github` and repository URL requests and the topic of natural requests
  ("list the artcraft apps from github"). GitHub's public repository/release metadata supplies Linux AppImage
  candidates, never helper-generated download commands; only x86_64/arm64 AppImages with published SHA-256
  digests are installable (verified with `sha256sum`, linked into `~/Applications`, never replacing or running a
  file). Repositories without one are listed with Open. No GitHub credentials; bounded metadata cached five
  minutes; API errors propagate (`github_failed`) instead of unrelated suggestions, and a GitHub failure in a
  general search keeps the package results (`github_unavailable`). Package and GitHub searches share bounded
  spacing/hyphen variants; Ask AI's spelling hints pass a lexical check. Install apps and Ask AI show GitHub
  results. Checked live: "pdfcraft" finds storytold/pdfcraft v0.21.1 with a digest-checked
  `pdfcraft-0.21.1-linux-x86_64.AppImage`; the misspelling "pdscraft" finds it through the helper's checked hint.
  Web discovery changed from the branch's per-question checkbox to the shared `web_search` setting of
  `maprisma-ai/settings.json` (Maprisma Settings › AI): when on and the shared helper is Claude Code (only
  WebSearch/WebFetch), an install request that found nothing, or one naming a website, asks the web for the
  official GitHub repository; the core verifies its release and the result says "Found on the web: site →
  github.com/owner/repo". Off or another helper: no web call; "nothing found" says why. Codex (`--search` keeps
  its shell tool) and Antigravity (no tool selection) have no web-only mode, so they are not offered.


## Downloaded AppImages (2026-11-14, ask-local-appimage)

- Added a bounded, owner-checked Downloads source to Ask AI and Install apps search.
- Local review records source, size, SHA-256 and destination; install copies offline,
  checks the reviewed content on an opened descriptor, syncs and atomically publishes
  without overwriting other files. Standalone scanning also recognizes type-2 magic.
- Core regression tests use temporary homes; Flutter covers the source label and
  direct install review. Socket-dependent suites cannot run fully in the restricted
  agent sandbox; see the task report for validation results.


## Shared Ask AI rules (2026-11-14, ask-ai-rules)

- Core-issued per-target proposals bind Ask actions to their target/source; every
  Launcher execution boundary enforces the current shared rules, including after
  asynchronous preparation. Manual operations omit provenance and stay unrestricted.
- Ask results fetch current rules, retain disabled suggestions with a Settings AI
  link, and carry ids through reviews, shortcut cards, batches and both terminal paths.
- Shared helper writes and action logs use persistent libc flock locks; corrupt
  shared settings cannot be overwritten by a helper change. Downloads denial is
  scoped to Ask discovery and AI local installs, including cached reviews.
- Regression coverage uses temporary homes, synthetic helper/package data and two
  concurrent writer processes. See protocol.md for parameters and docs/reviews/
  ask-ai-rules-implementation.md for validation and implementation differences.
