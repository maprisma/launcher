# App Manager protocol (version 1)

GUI (`flutter_app`) ↔ core (`packages/appmanager_core`, in a background isolate).
A request is `{"id", "protocol": 1, "method", "params"}`, the answer `{"id", "result"}` or
`{"id", "error": {"code", "message"?}}`. Requests ≤ 64 KiB, answers ≤ 4 MiB.

| Route | Params | Result |
|---|---|---|
| `core.hello` | — | `version`, `protocol`, `desktop` |
| `desktop.look` | — | `desktop` (omarchy, gnome, cosmic, generic), `colors` (background, foreground, accent, selection, muted, red, yellow, orange, green; empty on generic), `rounding` (px or null), `icon_theme` |
| `apps.list` | — | `apps`: the scan (keys as launcher_core.parse_desktop_files) plus `key` and `icon_file`; `icon_theme` |
| `apps.launch` | `key` | `started`; errors `unknown_app`, `launch_failed` |
| `apps.action` | `key`, `action` | as apps.launch, for one of the entry's own actions |

Errors: `bad_request`, `unknown_route`, `bad_params`, `internal`.
