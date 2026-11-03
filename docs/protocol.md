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
| `groups.get` | — | `groups` [{`id`, `name`, `builtin`, `new`}], `collapsed`, `origins` |
| `groups.place` | `key`, `group`, `target`?, `after`? | the groups; refusals as `refused` with the reason |
| `groups.add` | `name`, `key`? | the groups, `result` = new id |
| `groups.rename` / `groups.delete` / `groups.move` / `groups.reorder` / `groups.toggle` | `id` (+ `name` / `delta` ±1 / `target`, `after`) | the groups |
| `settings.get` / `settings.set` | — / `key`, `value` | the checked settings; `bad_params` when a value does not fit |

Errors: `bad_request`, `unknown_route`, `bad_params`, `unknown_app`, `refused` (with `message`), `internal`.
