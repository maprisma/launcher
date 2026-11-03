2026-11-03T12:34:51Z
### Verification of Previous Review Fixes (`00856a2`)

All 8 fixes in `00856a2` are complete and verified:
- [`Tray.belongsTo`]: uses [`appProcessName`] (rejecting shared interpreters), excludes shared Electron runtimes (`^electron[0-9]*$`), and only checks `app['argv']` for AppImage/CLI entries.
- [`CosmicSettings._read`] & [`_cosmicBackend`]: uses non-blocking, size-capped [`Posix.readRegular`] and falls back to read-only (`null` backend) when unreadable or unparseable.
- [`HyprBackend.save`]: records `before = await configErrors()` prior to writing and only rolls back when `errors.isNotEmpty && errors != before`.
- [`runBounded`], [`ShellPlugins.update`], and [`_PluginsPageState._do`]: captures bounded stdout + stderr and surfaces the failure reason in the snackbar.
- [`Posix.ownerOf(follow: false)`] & [`Admin`]: checks `AT_SYMLINK_NOFOLLOW` (`0x100`) on the session record and admin flag file.
- [`PopupGuard.around`] around `admin.enable`, [`apps_page.dart`] hiding the popup on terminal `started`, and [`sessionRun`] forwarding `session.environment` to `gsettings` and `hyprctl`.

---

### Findings (`109bfe3..b1d295d`)

1. **Medium** — [`flutter_app/lib/overview.dart:704-705`], [`flutter_app/lib/overview.dart:717-735`]
   - **Scenario:**
     1. **State desynchronization between `overviewFilter` and `page` mid-turn:** [`_CubeOverviewState.didUpdateWidget`] compares `widget.front` against `final front = _wrap(page.value.round())` rather than the in-flight animation target. During the first half of a 320 ms turn from face `0` to face `1` (`page.value < 0.5`), `page.value.round()` is still `0`. If the user clicks back to face `0` in the footer, presses `ArrowRight` then `ArrowLeft` within ~150 ms, or presses `ArrowRight` / `Ctrl+G` twice with 2 groups (`0 → 1 → 0`), `widget.front != front` evaluates to `false` and [`_turnTo`] is skipped. The `AnimationController` finishes animating to face `1` and stays there visually while `overviewFilter`, the active footer chip, `visibleApps`, and `Enter` are on face `0`. Similarly, [`_step`] (mouse wheel) computes `_wrap(page.value.round() + step)` instead of stepping from the target face, dropping rapid wheel ticks during the first half of a turn.
     2. **Wrap-around with 1 or 2 groups:** When `count == 2`, `(index - page.value) % 2` in Dart is `+1.0` and `diff > count / 2` (`1.0 > 1.0`) is false, so [`_turnTo`] always rotates in the `+1.0` direction even when `ArrowLeft` or `Ctrl+Shift+G` was pressed. When `count == 1`, horizontal dragging still changes `page.value`, turning `isFront` (`diff.abs() < 0.15`, line 814) false after 39 px (wrapping the only face in `IgnorePointer` until settle) and jumping from `-30°` to `+30°` at `page.value == 0.5`.
   - **Fix:** Track the target face index (e.g. `int _target = widget.front;`) in [`_CubeOverviewState`] so `didUpdateWidget` and `_step` compare/step from `_target` rather than `page.value.round()`; pass or infer the step sign when `count == 2`; and make drag/wheel/turn a no-op when `count <= 1`.

2. **Medium** — [`flutter_app/lib/overview.dart:447`], [`flutter_app/lib/overview.dart:485-492`], [`flutter_app/lib/apps_page.dart:1196`]
   - **Scenario:** In [`_cubeFace`], `_iconTile(members[i], false, ...)` hardcodes `isSelected = false`, and `_cubeFace` never updates `_columns` for the front face. When the user presses `ArrowDown` or `ArrowUp` in the Cube layout ([`_onKey`]), `selectedKey` is updated (and `Enter` launches that app), but no selection highlight is ever rendered on the Cube face, `_selectedItem` is never attached for `Scrollable.ensureVisible`, and `ArrowDown`/`ArrowUp` steps by whatever stale `_columns` value was left from a previous layout (or `1` if the app started in Cube layout) instead of the front face's column count.
   - **Fix:** In [`_cubeFace`], when `isFront` is true, set `_columns = columns;` and pass `isFront && members[i]['key'] == selectedKey` as the second argument (`isSelected`) to `_iconTile`.

3. **Medium** — [`flutter_app/lib/dock_app.dart:188`], [`flutter_app/lib/dock_app.dart:243-245`]
   - **Scenario:**
     1. [`_dockState`] puts `icons.json` in `watch` so the dock updates immediately when an app's icon is changed or reset in Maprisma Launcher (matching `icons.apply(self.apps, icons.load())` in [`dock.py:219`]). However, [`_reloadSettings`] calls `await _refresh(force: true)` with `rescan: false`. Because [`dock.items`] only re-runs `_listApps()` when `params['rescan'] == true || _listed.isEmpty`, the dock's `CoreService` continues returning the old `icon_file` from `_listed` for up to 60 seconds.
     2. In [`_refresh`], `if (_refreshing) return;` drops any concurrent call while a 4-second poll or event settle is awaiting `dock.items`. If the user pins/unpins an app in the dock menu ([`_run`]), finishes dragging a pinned icon ([`_endDrag`]), or triggers [`_reloadSettings`] while a poll is in flight, the forced refresh is dropped and the in-flight poll finishes with stale state.
   - **Fix:** Call `await _refresh(rescan: true, force: true)` in [`_reloadSettings`], and if `_refresh` is called while `_refreshing` is true, coalesce the pending `force`/`rescan` flags and run one follow-up pass when the active `dock.items` call completes.

4. **Low** — [`packages/maprisma_launcher_core/lib/src/dock.dart:425-435`]
   - **Scenario:** [`HyprEvents._connect`] checks `if (_stopped) return;` before `await Socket.connect(...)`, but not after it resolves. If [`stop()`] is called while `Socket.connect` is in flight, `_connect` still assigns `_socket` and starts listening after `stop()` has completed.
   - **Fix:** Check `if (_stopped) { socket.destroy(); return; }` immediately after `await Socket.connect(...)`.


---

## Claude's check (2026-11-03), each finding against the code

| # | Verdict | Change |
|---|---|---|
| 1 | Confirmed: a turn reversed before it was half done kept turning the old way, so the state and the picture differed. The two-face direction and the one-face drag were cosmetic but are fixed too. | `_CubeOverviewState._target`: turns are counted from the face the cube is heading to; two faces turn the way the key asked (`direction`); one face cannot be dragged or turned; groups added/removed reset without a turn. The regression test (Right, then Left at once) fails with the old comparison. |
| 2 | **False**: `_cubeFace` sets `_columns` for the front face and passes the selection (`members[i]['key'] == selected`). | none |
| 3 | Mostly **false**: a file change already refreshes with `rescan: true`, and a refresh during another one is queued (`_again`). Real part: the queued pass dropped `rescan`. | `_againRescan` keeps it. |
| 4 | **False**: there is no `_connect`/`_stopped`; when stop completes during the connect, `stop?.then(socket.destroy)` closes the new socket at once. | none |
