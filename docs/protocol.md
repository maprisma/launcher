# App Manager protocol (version 1)

GUI (`flutter_app`) ↔ core (`packages/appmanager_core`, in a background isolate).
A request is `{"id", "protocol": 1, "method", "params"}`, the answer `{"id", "result"}` or
`{"id", "error": {"code", "message"?}}`. Requests ≤ 64 KiB, answers ≤ 4 MiB.

| Route | Params | Result |
|---|---|---|
| `core.hello` | — | `version`, `protocol`, `desktop`, `imported` (what the first start copied) |
| `desktop.look` | — | `desktop` (omarchy, gnome, cosmic, generic), `colors` (background, foreground, accent, selection, muted, red, yellow, orange, green; empty on generic), `rounding` (px or null), `icon_theme` |
| `apps.list` | — | `apps`: the scan (keys as launcher_core.parse_desktop_files) plus `key`, `icon_file`, `hidden`, `group`, `origin`, `roles`; `icon_theme`; the groups |
| `apps.launch` | `key` | `started`; errors `unknown_app`, `launch_failed` |
| `apps.action` | `key`, `action` | as apps.launch, for one of the entry's own actions |
| `apps.sections` | `view` (groups, origin), `keys` (the shown entries, in order) | `sections` [{`id`, `keys`}], plus the groups |
| `apps.hide` | `key`, `hidden` | `hidden` |
| `apps.facts` | — | `facts`: {app key: size, package, version, … (details.app_facts)} |
| `apps.running` | — | `running` (app keys); on Omarchy and COSMIC also `states` {key: `active` (open windows) or `background`} |
| `apps.windows` | `key` | `windows` (the app's Hyprland or COSMIC windows: `address`, `title`, `workspace`; empty on desktops without a window source) |
| `apps.close` | `key`, `address`? (one window `apps.windows` listed; none: all) | `closed` (how many of the app's windows were asked to close, as their ✕); `not_available` without Hyprland/COSMIC window management |
| `window.focus` | `address` (one `apps.windows` just listed) | `focused`; `not_found`, `focus_failed` |
| `apps.open_floating` | `key` | `started` (Hyprland exec with float); `launch_failed` |
| `apps.open_on_workspace` | `key`, `workspace` (int) | `started`; `bad_params`, `launch_failed` |
| `workspaces.list` | — | `workspaces` (in use, with their apps), `free` (the next empty one) |
| `window.popup` | `width`, `height` | Omarchy: the popup floated and centred (`placed`); elsewhere `placed` false |
| `term.start` | `action` (`install` + `manager`, `package` from the last search; `uninstall` + `key`; `uninstall_all` + `keys`, `manager`: that manager's packages of the combined plan, minus blocked ones, in one line; `system`), `cols`?, `rows`? | `id`, `command` (shown); the program runs in a pseudo terminal (setsid -w -c, sudo asks there); `not_found`, `not_terminal` (nothing needs a terminal / the desktop's own updater), `no_pty`, `busy` (4 at once) |
| `term.read` | `id` | `data` (base64, the output since the last read, at most 1 MiB kept), `ended`, `code` |
| `term.write` / `term.resize` / `term.close` | `id` + `data` (base64, ≤ 64 KiB) / `cols`, `rows` / — | `accepted`, `ended` / `resized` / `closed` (a running program gets a hangup) |
| `apps.quit_check` | `key` | `label`: the app's own tray Quit entry (StatusNotifierItem menu), or null |
| `apps.quit` | `key` | `clicked` (that entry, looked up again; we never end processes); `no_quit`, `quit_failed` |
| `admin.state` | — | `enabled` (this login session), `available` (pkexec and a session to tie it to) |
| `admin.enable` | `on` | `enabled`; turning it on asks polkit for the password first (`not_confirmed`) |
| `apps.admin_check` / `apps.admin_launch` | `key` | `can` / `started`; `not_enabled`, `launch_failed` |
| `apps.uninstall_plan` | `key` | `kind` (null, `flatpak`, `package` + `manager`, `webapp`, `omarchy` + `how`, `trash`), `what`, `warnings`, `needed_by` (packages: installed packages that still need it) |
| `apps.uninstall` | `key` | what the plan said: started in a terminal, or done |
| `apps.uninstall_all_plan` | `keys` | `packages` (per `manager`: `what` (each once), `apps`, `omarchy`), `blocked` (`what`, `needed_by`, `apps`: other installed packages still need it, pacman would refuse), `others` (no terminal: trash, Flatpak, Omarchy entries), `skipped` (web apps, nothing owns it) |
| `updates.check` | `force`? | `apps` {desktop path: [package, old, new]}, `flatpaks` {key: …}, `appimages` {key: release details}, `appimage_unknown` {key: reason}, `appimage_restorable` [keys], `checked` |
| `updates.flatpak` | `key` | the updates; `bad_params`, `update_failed` |
| `updates.appimage` | `key` | installs a verified newer AppImage from embedded GitHub update information at its existing path, keeping the previous binary as `.bak`; `no_update`, `busy`, `update_failed` |
| `updates.appimage_restore` | `key` | swaps the previous AppImage back into its existing path; `busy`, `restore_failed` |
| `updates.system` | — | `started` (the desktop's own updater); `no_updater` |
| `packages.managers` | — | `managers` [{`id`, `label`, `program`, `enabled`}] |
| `packages.search` | `query` | `results` of the enabled managers |
| `packages.install_plan` / `packages.install` | `manager`, `package` (from the last search) | `argv`, `command` (shown), `aur` / `started`; `not_found`, `no_terminal` |
| `ask.helpers` | — | `helpers` [{`command` (the helper id: every agent of Maprisma's helpers catalog with an `ask` — `/usr/lib/maprisma/data/helpers.json` when at least as new as the shipped copy — in its order; claude, codex, agy, pi and hermes with the Launcher's own stricter setups and always listed, other catalog agents only when installed; then `pi:<provider>/<model>` for pi's other models), `name`, `installed`, `signed_in` (a catalog agent: when installed), `local`? (runs on this PC), `catalog`? (run by the catalog's argv), `verified` (false: "(untested)"), `login`, `note`}], `choice` (the shared choice of all Maprisma apps, `${XDG_CONFIG_HOME:-~/.config}/maprisma-ai/settings.json` key `helper`: `auto` or an id; missing/invalid = `auto`; before that file exists, the Launcher's former `ask_helper`), `chosen` (the id it means now: the chosen one when installed, else the first installed that seems signed in, else the first installed; null when none), `shared_file` |
| `ai.helper.set` | `helper` (`auto` or an id matching `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$`) | writes the shared choice (other keys kept; tmp + rename, folder 0700, file 0600) and answers as `ask.helpers`; `bad_params`, `write_failed` |
| `ask.run` | `helper`, `request`, `answer`?, `language`? | the checked answer: `action` install (`picks`, `installed`, `summary`), remove / update / explain / hide / unhide (`apps`), list_hidden (`apps`: the hidden ones, from the core), shortcuts (`apps`; none named: every app with a shortcut, from the core), remove_shortcut (`apps`, `shortcut` label to mark), add_shortcut (`apps`: one, `mods`, `key`? — a proposal the shortcut card presets), update_system, clarify (`question`, `choices`), redirect (`hint`); `no_helper`, `helper_failed` (with the reason) |
| `ask.cancel` / `ask.signin` | — / `command` | `cancelled` / `started` (the helper's login in a terminal; `bad_params` for a catalog agent, which has no login here) |
| `icons.search` | `key`, `query` | `theme` [{`name`, `file`}], `online` [{`collection`, `slug`, `url`}] |
| `icons.preview` | `url` (one just found), `color`? | `file` |
| `icons.set` / `icons.reset` | `key`, `name` or `url`, `color`? / `key` | `set` / `reset`; `not_found`, `download_failed` |
| `open.url` | `url` (http/https only) | `started`; `bad_params`, `no_opener` |
| `plugins.list` | — | Omarchy shell plugins: `plugins` [{`plugin_id`, `name`, `description`, `version`, `bar_widget`, `in_bar`, `openable`, `removable`, `plugin_dir`, `behind`?}] |
| `plugins.open` / `plugins.bar` | `plugin_id` / + `placed`, `section`? | `opened` / `done`; `open_failed`, `bar_failed` |
| `plugins.remove_plan` / `plugins.remove` | `plugin_id` | `note` (link, backup, deleted, loses), `loses_work`, counts / `removed` |
| `plugins.updates` / `plugins.update` | `force`? / `plugin_id` | `behind` {id: commits} / `updated`; `update_failed` |
| `groups.get` | — | `groups` [{`id`, `name`, `builtin`, `new`}], `collapsed`, `origins` |
| `groups.place` | `key`, `group`, `target`?, `after`? | the groups; refusals as `refused` with the reason |
| `groups.add` | `name`, `key`? | the groups, `result` = new id |
| `groups.rename` / `groups.delete` / `groups.move` / `groups.reorder` / `groups.toggle` | `id` (+ `name` / `delta` ±1 / `target`, `after`) | the groups |
| `shortcuts.state` | `key`, `mods`? (the key map's modifiers), `action`?, `editing`? ({`mods`, `key`, `action`, `external`}: the shortcut being changed), `fresh`? (read the desktop again) | `available`, `desktop` (GNOME, COSMIC, Omarchy; null on generic), `default_mods`, `actions`, `shortcuts` [{`mods`, `key`, `then`?, `label`, `source` (launcher, external), `action`, `replaces`, `duplicate` / `file`, `description`}], `disabled` [{…, `description`, `source`}], then `keys` [{`key`, `label`, `level`, `owner`}] for every key of the map (with `mods`) or `suggestions` (without) |
| `shortcuts.set` | `key`, `mods`, `combo_key` (one of the key map's keys), `action`?, `editing`? | `saved`, `level`, `owner`; `refused` when the key already does this, `not_available`, `not_applied` (the desktop refused it; nothing changed) |
| `shortcuts.remove` / `shortcuts.disable` / `shortcuts.restore` | `key`, `combo` {`mods`, `key`, `then`?} | `saved`; `not_found` |
| `shortcuts.labels` | — | `labels`: {app key: [combo labels]} of the launcher's shortcuts |
| `shortcuts.default_mods` | `mods` (empty: back to Super + Shift) | `default_mods` |
| `dock.state` | — | `settings` (dock_*: dock_core.settings), `bar` (shell.json's edge), `edge` (never the bar's), `sizes` {`band`, `item`, `room`, `grow`}, `available` (Omarchy, Hyprland and gtk-layer-shell), `reason` (`not_omarchy`, `no_layer_shell`), `look`, `indicator_color`, `corners`, `watch` (files the dock follows) |
| `dock.set` / `dock.reset` | `key`, `value` (a dock_* setting; not `dock_pinned`) / — | the state; `bad_params` |
| `dock.pin` | `key`, `pinned`? (false: unpin) | `pinned` (desktop ids, in order) |
| `dock.move` | `id`, `target` (both pinned), `after`? | `pinned`; `not_found` |
| `dock.items` | `rescan`? | `items` [{`key`, `desktop_id`, `name`, `icon_file`, `actions` (≤ 6), `pinned`, `windows` (addresses, last focused first), `new_window_action`}], `active` (focused address) |
| `dock.activate` | `key` | `focused` (its next window, from a fresh window list) or `started`; `focus_failed`, `launch_failed` |
| `dock.close` | `key` | `closed` (windows asked to close) |
| `dock.start` / `dock.open_manager` | — | `started` (`maprisma-launcher --dock` only when on and available; `--toggle`) |
| `settings.get` / `settings.set` / `settings.reset` | — / `key`, `value` / — | the checked settings; `bad_params` when a value does not fit |

Errors: `bad_request`, `unknown_route`, `bad_params`, `unknown_app`, `refused` (with `message`), `internal`.

Shortcut levels (`keys[].level`): `free`, `same` (already opens this), `retarget` (opens another action of this
app), `launcher` (another app's launcher shortcut: it moves), `custom` (the user's own shortcut), `desktop` (the
desktop's default: GNOME, COSMIC, Omarchy). Modifiers are SUPER, SHIFT, CTRL, ALT; keys only those of the key map
(`keyMapRows` in shortcuts.dart); actions only the entry's own.

COSMIC window routes use the bundled `maprisma-launcher-windows` helper (then PATH),
with bounded output and a deadline. It uses ext-foreign-toplevel-list and COSMIC
toplevel info/management, waits up to 500 ms for the initial info batch, and
returns stable opaque identifiers in the existing `address` field. Identifiers
must be nonempty, at most 512 characters, and contain no control characters.
Focus accepts only a previously listed id; close re-reads windows and only
closes those belonging to the requested app.

COSMIC matches app_id case-insensitively against desktop_id (without .desktop),
StartupWMClass, or the Exec basename. Terminal-command entries never claim
a terminal window; their running command gives them `background` state.
`active` means an open window, including unfocused windows on other workspaces.
The Running card/section and footer Running filter select only `active` when
states are supplied, while background marks remain in ordinary groups.
GNOME/generic retain process-based running selection without states. If the
COSMIC helper is missing or unavailable, states are omitted and process-based
selection is used until a window snapshot can be obtained.
