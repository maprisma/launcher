### Findings

1. **Medium** — [`shortcuts.dart:994`](packages/maprisma_launcher_core/lib/src/shortcuts.dart#L994), [`shortcuts.dart:1008-1013`](packages/maprisma_launcher_core/lib/src/shortcuts.dart#L1008-L1013), [`shortcut_service.dart:337-342`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L337-L342)
   - **Scenario:**
     1. Unlike [`HyprBackend._read`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L173-L176) (which uses `Posix.instance.readRegular(path, 1024 * 1024)`), [`CosmicSettings._read`](packages/maprisma_launcher_core/lib/src/shortcuts.dart#L1008-L1013) reads `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom` and `/usr/share/cosmic/.../defaults` with `file.existsSync()`, `file.lengthSync()`, and `file.readAsStringSync()`. If `custom` is a FIFO or symlink to a pipe/special file (`lengthSync() == 0`), `readAsStringSync()` blocks the isolate indefinitely and reads without bound.
     2. [`CosmicSettings`](packages/maprisma_launcher_core/lib/src/shortcuts.dart#L989-L995) calls `_load()` synchronously in its constructor, and [`backendFor`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L337-L342) instantiates `cosmicSettings(...)` eagerly before constructing [`GnomeBackend`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L55-L61). If the user's COSMIC `custom` shortcut file has a syntax error or exceeds 1 MiB, `parseCosmicShortcuts` throws `FormatException` during `CoreService.shortcuts` initialization, breaking both `shortcuts.*` and `apps.list` (which calls [`shortcuts.summary()`](packages/maprisma_launcher_core/lib/src/core.dart#L550)) before `GnomeBackend.available()`'s `try / on Object` can catch it.
   - **Fix:** Replace `File(path).readAsStringSync()` in `CosmicSettings._read` with `Posix.instance.readRegular(path, 1024 * 1024)` (and `Posix.instance.isRegular(defaultsFile)` in `available()`), and defer `_load()` out of the `CosmicSettings` constructor (or guard initial load inside `available()` / `summary()`).

2. **Medium** — [`settings_page.dart:51-70`](flutter_app/lib/settings_page.dart#L51-L70), [`main.dart:83-90`](flutter_app/lib/main.dart#L83-L90)
   - **Scenario:** When the user switches on **"Open as administrator"** in Settings while in popup mode (the default on Omarchy), [`_setAdmin`](flutter_app/lib/settings_page.dart#L51-L70) calls `widget.core('admin.enable', {'on': true})`, which runs `pkexec /usr/bin/true` ([`admin.dart:122`](packages/maprisma_launcher_core/lib/src/admin.dart#L122)). The desktop polkit agent dialog takes window focus away from the launcher. Because `_setAdmin` does not wrap the call in [`PopupGuard.around(...)`](flutter_app/lib/main.dart#L42-L52) (unlike the folder picker at [`settings_page.dart:321`](flutter_app/lib/settings_page.dart#L321)), [`_onFocus`](flutter_app/lib/main.dart#L83-L90) hides the popup 250 ms after the polkit prompt opens; when the popup is shown again, `AppsPage._onShown()` runs while `SettingsPage` is still on top of the `Navigator`.
   - **Fix:** Wrap `widget.core('admin.enable', {'on': on})` in `PopupGuard.around(...)` in [`settings_page.dart:55`](flutter_app/lib/settings_page.dart#L55).

3. **Medium** — [`posix.dart:132-136`](packages/maprisma_launcher_core/lib/src/posix.dart#L132-L136), [`admin.dart:55`](packages/maprisma_launcher_core/lib/src/admin.dart#L55), [`admin.dart:64`](packages/maprisma_launcher_core/lib/src/admin.dart#L64), [`admin.dart:83-85`](packages/maprisma_launcher_core/lib/src/admin.dart#L83-L85)
   - **Scenario:**
     1. [`Posix.ownerOf`](packages/maprisma_launcher_core/lib/src/posix.dart#L132-L136) calls `_statx(_atFdCwd, name, 0, _statxUid, buffer)` with flags `0` instead of `_atSymlinkNofollow` (`0x100`), so it follows symlinks (unlike `isRegular` and `dirMode` right below it, and unlike `os.lstat` in [`reference/omarchy-plugin/launcher_core.py:80, 110`](reference/omarchy-plugin/launcher_core.py#L80-L110)).
     2. In [`admin.dart:83-85`](packages/maprisma_launcher_core/lib/src/admin.dart#L83-L85), `enabled()` checks `ownerOf(flag)` by path before opening `flag` in `readRegular(flag, 256, follow: false)`, whereas [`reference/omarchy-plugin/launcher_core.py:138-145`](reference/omarchy-plugin/launcher_core.py#L138-L145) checks `info.st_uid == os.getuid()` on the `os.fstat(fd)` result of the `O_NOFOLLOW`-opened descriptor.
   - **Fix:** Pass `_atSymlinkNofollow` in [`Posix.ownerOf`](packages/maprisma_launcher_core/lib/src/posix.dart#L134), and verify `_uid(stat) == expectedUid` on the opened file descriptor inside [`Posix.readRegular`](packages/maprisma_launcher_core/lib/src/posix.dart#L173-L176) when `owner` is required.

4. **Medium** — [`tray.dart:270-284`](packages/maprisma_launcher_core/lib/src/tray.dart#L270-L284) (vs [`reference/omarchy-plugin/launcher_popup.py:6546-6555`](reference/omarchy-plugin/launcher_popup.py#L6546-L6555))
   - **Scenario:** In [`reference/omarchy-plugin/launcher_popup.py:6553-6554`](reference/omarchy-plugin/launcher_popup.py#L6553-L6554), `tray_app` matches `item["tray_programs"]` against `app_process_name(a)` (which skips `env` prefixes and refuses shared interpreters/wrappers `sh`, `bash`, `env`, `flatpak`, `gtk-launch`, `python`, `python3`, `java`, as well as terminal wrappers) or `Path(a.get("argv", [""])[0]).stem.casefold()`.
     In [`Tray.belongsTo`](packages/maprisma_launcher_core/lib/src/tray.dart#L277-L280), it instead splits `app['exec']` and checks `programs.contains(p.basenameWithoutExtension(args.first).toLowerCase())`:
     - If an app's `Exec=` starts with `env VAR=val /usr/bin/foo`, `args.first` is `'env'`, so it misses `foo` (and matches any tray process that happened to have `env` in `programs`).
     - If any Python or Electron tray app is running, [`programsOf`](packages/maprisma_launcher_core/lib/src/tray.dart#L99) records its `/proc/<pid>/exe` basename (`python3` or `electron`) in `tray_programs`. `Tray.belongsTo` then matches **every** installed app whose `Exec=` starts with `python3 ...` or `electron ...` to that tray icon, so choosing **Quit** on an unrelated Python/Electron app clicks the tray icon's Quit entry.
   - **Fix:** In [`Tray.belongsTo`](packages/maprisma_launcher_core/lib/src/tray.dart#L277-L280), match `programs` against `appProcessName(app)` from [`running.dart`](packages/maprisma_launcher_core/lib/src/running.dart#L38-L60) (and `argv.first` stem for standalone AppImages), and exclude `'electron'` alongside `_shared` in `appProcessName`.

5. **Medium** — [`shortcut_service.dart:306-322`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L306-L322)
   - **Scenario:** In [`HyprBackend.save`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L306-L307):
     ```dart
     final oldLua = File(luaFile).existsSync() ? _read(luaFile) ?? '' : null;
     final before = oldLua != null ? await configErrors() : '';
     ```
     When `maprisma-launcher-shortcuts.lua` does not exist yet (`oldLua == null`), `before` is `''` instead of the current output of `configErrors()`. If the user's `hyprland.lua` already has an unrelated config error, saving the first shortcut sees `errors.isNotEmpty && errors != before`, rolls back `luaFile` to `''` and deletes `shortcuts.json`, leaves `require("hypr.maprisma-launcher-shortcuts")` appended to `hyprland.lua`, and throws `ServiceError('not_applied', ...)`.
   - **Fix:** Always read `final before = await configErrors();` before writing `luaFile` and calling `ensureRequired()`.

6. **Medium** — [`shortcut_service.dart:283-301`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L283-L301) (vs [`reference/omarchy-plugin/shortcuts.py:68-96`](reference/omarchy-plugin/shortcuts.py#L68-L96))
   - **Scenario:** [`HyprBackend.desktopArg`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L293-L297) creates `~/.local/state/maprisma-launcher/desktop-ids` with default permissions, does not verify that `aliasDir` is a real directory owned by `uid` with mode `0700`, and deletes + recreates the symlink non-atomically (`link.deleteSync(); link.createSync(desktopPath);`) on every `renderLua` call. The Python reference ([`shortcuts.py:79-93`](reference/omarchy-plugin/shortcuts.py#L79-L93)) checks `lstat(DESKTOP_ALIAS_DIR)` for directory type, `uid`, and no group/world write bits, returns early when the symlink already points to `path`, and replaces it atomically via a temporary symlink + `os.replace`.
   - **Fix:** Verify `Posix.instance.ownerOf(aliasDir) == Posix.instance.uid` and `(Posix.instance.dirMode(aliasDir)! & 0x3f) == 0` (after `chmod(aliasDir, 0x1c0)`), return `alias` immediately when `FileSystemEntity.isLinkSync(alias) && Link(alias).targetSync() == desktopPath`, and replace via a temporary symlink in `aliasDir` + `Posix.instance.rename`.

7. **Low** — [`plugins.dart:224-231`](packages/maprisma_launcher_core/lib/src/plugins.dart#L224-L231), [`core.dart:226-230`](packages/maprisma_launcher_core/lib/src/core.dart#L226-L230), [`plugins_page.dart:69-71`](flutter_app/lib/plugins_page.dart#L69-L71) (vs [`reference/omarchy-plugin/updates.py:62-84`](reference/omarchy-plugin/updates.py#L62-L84))
   - **Scenario:**
     1. [`ShellPlugins.update`](packages/maprisma_launcher_core/lib/src/plugins.dart#L228-L230) calls `readBoundedText([omarchy, 'plugin', 'update', id, '--yes'], ...)` with default `okCodes = const {0}`. Because [`readBoundedBytes`](packages/maprisma_launcher_core/lib/src/bounded.dart#L29-L56) discards `stderr` and returns `null` whenever `exitCode != 0`, `out` is always `null` on failure. Unlike [`updates.py:69-84`](reference/omarchy-plugin/updates.py#L69-L84) (which merges stderr into stdout and extracts the last line on non-zero exit), `ShellPlugins.update` always loses the command's error message and falls back to `'the update failed'`.
     2. In [`plugins_page.dart:70`](flutter_app/lib/plugins_page.dart#L70), `_tell(e.reason ?? trf('Could not update {0}', [name]))` shows raw English fallback strings (`'the update failed'`, `'no omarchy command'`) without `tr()` and without the `trf('Could not update {0}', [name])` prefix.
   - **Fix:** Capture stdout+stderr on non-zero exit (or pass `okCodes: const {}` and return `(code == 0, lastLine)`), and format the error in `plugins_page.dart` with `trf('Could not update {0}', [name])`.

8. **Low** — [`apps_page.dart:898-906`](flutter_app/lib/apps_page.dart#L898-L906), [`core.dart:819-822`](packages/maprisma_launcher_core/lib/src/core.dart#L819-L822), [`core.dart:841-845`](packages/maprisma_launcher_core/lib/src/core.dart#L841-L845) (vs [`reference/omarchy-plugin/launcher_popup.py:3961-3962`](reference/omarchy-plugin/launcher_popup.py#L3961-L3962))
   - **Scenario:** When uninstalling a package or Flatpak, `_uninstall` in [`core.dart`](packages/maprisma_launcher_core/lib/src/core.dart#L821-L845) spawns the terminal or `omarchy-remove-launcher-entry` and returns `{'started': true}`. [`AppsPageState._uninstall`](flutter_app/lib/apps_page.dart#L898-L906) only acts on `result['done'] == true` and does not call `widget.onHide?.call()` when `result['started'] == true` (unlike [`_updateSystem`](flutter_app/lib/apps_page.dart#L1030) and [`launcher_popup.py:3961-3962`](reference/omarchy-plugin/launcher_popup.py#L3961-L3962)).
   - **Fix:** Add `else if (result['started'] == true) { widget.onHide?.call(); }` in [`apps_page.dart:902`](flutter_app/lib/apps_page.dart#L902).

9. **Low** — [`shortcut_service.dart:39-40`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L39-L40), [`shortcut_service.dart:122-131`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L122-L131), [`shortcut_service.dart:146`](packages/maprisma_launcher_core/lib/src/shortcut_service.dart#L146)
   - **Scenario:** `boundedRun` does not pass `environment: session.environment` to `readBoundedText`, so `gsettingsProgram`, `gnomeFavorites`, and `HyprBackend.run` (`hyprctl`) ignore `session.environment` when `Session` has a custom environment.
   - **Fix:** Forward `environment: session.environment` in `gsettingsProgram`, `gnomeFavorites`, and `HyprBackend`.

### Verification Notes
- Core (`dart test`, 52 tests), widget (`flutter test`, 20 tests), and `tools/i18n.py --check` (331 texts per language, 0 missing) all ran and passed.
- Live Hyprland submap dispatch (`hyprctl dispatch` / `hyprctl eval`) and live Xwayland `XAddHost` were reviewed statically and via the fake-backed unit tests, per the read-only / no-`hyprctl` constraint.
TRUNC None

---

## Claude's check (2026-11-03), each finding against the code

| # | Verdict | Change |
|---|---|---|
| 1 | Confirmed: a FIFO/huge COSMIC file hung or broke the shortcut routes. Not confirmed: `apps.list` does not call the shortcut service. | `_read` through `Posix.readRegular` (non-blocking, ≤ 1 MiB, regular only; unreadable → throws, never rewritten); an unreadable file makes COSMIC shortcuts read-only (`_cosmicBackend` → null). Test: FIFO and > 1 MiB. |
| 2 | Confirmed | `admin.enable` inside `PopupGuard.around` (the polkit dialog takes the focus). |
| 3 | Low (XDG_RUNTIME_DIR is 0700 and ours; the flag is opened O_NOFOLLOW anyway) | `ownerOf(…, follow: false)` for the flag and logind's record. |
| 4 | Confirmed (port deviation: the reference uses `argv` only for AppImages/CLI tools, not Exec) | `belongsTo`: `appProcessName` (refuses shared interpreters) plus Electron runtimes refused; `argv` fallback only. Tests. |
| 5 | Confirmed (same in the reference) | Errors before are always read. Test fails with the old line. |
| 6 | **False**: owner, mode and link are checked, the matching link returns early, the swap is temp link + rename. | none |
| 7 | Confirmed | `runBounded` (stdout + stderr, one cap, one deadline); the last line as the reason, shown after "Could not update {0}" (7 languages). Test with a fake `omarchy`. |
| 8 | Confirmed | `started` hides the popup (the terminal needs the focus). |
| 9 | Confirmed | `sessionRun(session)` for gsettings and hyprctl. |
