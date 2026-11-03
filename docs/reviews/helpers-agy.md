2026-11-03T16:44:52Z
### Findings

1. **High** — [`ask_ai.dart:552-553`] & [`ask_ai_test.dart:255-256`]
   - **Scenario:** [`AskRunner.run`] unconditionally writes `utf8.encode(prompt)` to `process.stdin` and awaits `process.stdin.close()` even when `helper.argv.contains('{prompt}')` (Hermes, which receives the prompt via `-z {prompt}` and does not read `stdin`).
     1. When `hermes` exits before the parent finishes flushing `stdin`, `await process.stdin.close()` throws `SocketException: Write failed (OS Error: Broken pipe, errno = 32)`. Running `dart test` in `packages/maprisma_launcher_core` fails right now on [`test/ask_ai_test.dart:256`] with this exact `Broken pipe` error.
     2. When `prompt` exceeds the Linux pipe buffer (64 KiB, while line 516 permits up to 120 KiB for `{prompt}`) and `hermes` does not drain `stdin`, `await process.stdin.close()` blocks forever *before* `process.exitCode.timeout(...)` at line 559 is reached.
   - **Fix:** Attach `process.stdin.done.ignore();` (or catch `SocketException` on `stdin`), only write `prompt` to `process.stdin` when `!helper.argv.contains('{prompt}')`, and start the `stdout`/`stderr` listeners and `exitCode.timeout` before awaiting `stdin.close()` (or close `stdin` unawaited).

2. **High** — [`tools/install-local:58-68`] & [`pty.dart:98-103`]
   - **Scenario:** `terminal_busy` in [`tools/install-local`] never detects a running in-app terminal command, for two independent reasons:
     1. [`PtySession.start`] spawns `sh -c '... exec "$0" -w -c "$@"' setsid /dev/pts/N ...`. In `util-linux`, `setsid -w` always `fork()`s (`if (wait || getpgrp() == getpid()) fork()`): the direct child of `maprisma-launcher` (`$child`) is the waiting `setsid` parent process (still in the launcher's session, with no controlling tty), while the session leader on `/dev/pts/N` is the *grandchild* process (`pacman`/`yay`/`flatpak`). `terminal_busy` only inspects direct children (`/proc/$pid/task/*/children`).
     2. Even if `$child` were the session leader, `sed 's/^.*)//' "/proc/$child/stat" | awk '{print $6}'` extracts the 6th field *after* `(comm)`, which is `/proc/[pid]/stat` field 8 (`tpgid`), not field 6 (`session` / SID, which is `$4` after stripping `(comm)`).
     As a result, `tools/install-local` without `--force` will proceed to kill `maprisma-launcher` while `pacman`/`yay` is running in the in-app terminal, closing the PTY master fd and sending `SIGHUP` mid-transaction.
   - **Fix:** In `terminal_busy`, check whether any direct child of `maprisma-launcher` has `/proc/$child/fd/0` pointing to `/dev/pts/*` while `maprisma-launcher` itself holds `/dev/ptmx` open (or walk both `$child` and `/proc/$child/task/*/children` and use `awk '{print $4}'` for `session`).

3. **Medium** — [`ask_ai.dart:215`]
   - **Scenario:** In [`piModels`], `for (final m in conf['models'] as List? ?? const [])` performs an unchecked `as List?` cast outside the `try { ... } on FormatException` block. If `~/.pi/agent/models.json` has a non-list `"models"` value (e.g. a `Map` or `String`), `piModels` throws an uncaught `TypeError`, breaking `ask.helpers` and `ask.run` for all helpers.
   - **Fix:** Replace `conf['models'] as List? ?? const []` with `conf['models'] is List ? conf['models'] as List : const []`.

4. **Medium** — [`ask_ai.dart:129-160`]
   - **Scenario:** [`hermesModel`] parses `~/.hermes/config.yaml` with fixed 2/4-space indentation (`indent == 2`, `indent == 4`) and does not strip inline YAML comments (`# ...`).
     1. A config line with an inline comment such as `default: qwen2.5:7b # local` or `provider: ollama-local # local` keeps `# local` inside `value`, causing `_piName.hasMatch(model)` to fail or `apis[provider]` to miss (so `ensureLocalServer` is skipped and `local` is not set).
     2. Valid YAML formatted with 4-space indentation (or tabs) is silently ignored.
     3. `url.hasPort ? url.port : 80` at line 157 defaults `https://` URLs without an explicit port to `80` instead of `443` (unlike `piModels` at line 213).
   - **Fix:** Strip unquoted `# ...` inline comments before unquoting, track relative indentation per section/provider block rather than hardcoding `2` and `4`, validate `_piName.hasMatch(provider)`, and use `url.scheme == 'https' ? 443 : 80` when `!url.hasPort`.

5. **Medium** — [`ask_ai.dart:607`]
   - **Scenario:** In [`ensureLocalServer`], `await Process.run(systemctl, ['--user', 'start', unit], environment: session.environment)` has no timeout, and `_running` is not set during this phase so `ask.cancel` cannot abort it. If `systemctl --user start` blocks (e.g. a hung `Type=notify` unit or unresponsive user bus), `ask.run` hangs indefinitely. Also, if `ensureLocalServer` throws a descriptive `StateError` (lines 606, 608, 613), [`_askRun`] turns it into `ServiceError('helper_failed', '$e')` and [`ask_page.dart:123`] discards `e.message`, showing only generic `The helper did not answer.`
   - **Fix:** Run `systemctl --user start` with a bounded timeout (e.g. via `readBoundedText` or `--no-block` since lines 609–612 already poll the socket for up to 60s), and surface `ensureLocalServer` errors (or a dedicated error code) on `AskPage`.

6. **Medium** — [`ask_ai.dart:119`] & [`ask_ai.dart:534-536`]
   - **Scenario:** Passing `{prompt}` in `argv` (`hermes -t todo --ignore-rules -z <prompt>`) places the user's question, clarifying answer, and full installed-apps list (including hidden apps) into `/proc/<pid>/cmdline`, making it readable via `ps` to any other local user/process on the machine while `hermes` runs (unless `/proc` is mounted with `hidepid`). (Whether `hermes` supports reading the `-z` prompt from `stdin` or a file instead of `argv` could not be verified in this repo — **unverified**.)
   - **Fix:** If `hermes` supports reading the prompt from `stdin` or a `0600` file, pass it that way instead of in `argv`; otherwise document in the Hermes helper note that its prompt is passed on the command line.

7. **Medium** — [`ask_page.dart:132-140`]
   - **Scenario:** [`_newLine`] (`Ctrl+Enter`) mutates `request.value` directly, bypassing `TextField`'s `maxLength: 2000` input formatter, ignoring `if (asking) return;`, and dropping any active IME `composing` range:
     1. If the user is at 2000 characters and presses `Ctrl+Enter` between non-whitespace characters, `request.text.trim().length` exceeds 2000 and [`_askRun`] rejects the query with `That did not work (bad_params).`
     2. Pressing `Ctrl+Enter` while `asking == true` edits the controller text mid-request.
   - **Fix:** Guard `_newLine()` with `if (asking) return;` and check `if (value.text.length - (sel.end - sel.start) + 1 > 2000) return;` before inserting `\n`.

8. **Medium** — [`docs/protocol.md:19`], [`docs/protocol.md:38-39`]
   - **Scenario:** [`docs/protocol.md`] is out of sync with the core routes in three places:
     1. Line 19: `apps.close` lists only `key` in params, omitting optional `address` ([`core.dart:216`]).
     2. Line 38: `ask.helpers` omits optional `local` (`true` for local models) in the helper map ([`ask_ai.dart:264, 275`]).
     3. Line 39: `ask.run` omits the `hide` (`apps`), `unhide` (`apps`), and `list_hidden` (`apps`) actions ([`core.dart:881-891`]).
   - **Fix:** Update lines 19, 38, and 39 of [`docs/protocol.md`] to match `core.dart` and `ask_ai.dart`.

9. **Low** — [`ask_ai.dart:170-177`] & [`ask_ai.dart:282-292`]
   - **Scenario:** [`piListedModels`] does not deduplicate `(provider, model)` rows (unlike `piModels` which tracks `seen.add(id)`). If `pi --list-models` emits duplicate `(provider, model)` lines, [`helperStates`] produces duplicate `'command': 'pi:${m.provider}/${m.model}'` entries, which triggers an assertion error in Flutter's [`DropdownButton<String>`]. Also, line 283 checks `l.provider == m.provider` instead of `(l.provider == m.provider && l.model == m.model)`, hiding online models if a provider name is shared, and skips the header via `.skip(1)` which can drop the first model if `pi --list-models` ever prints without a header or include a separator row if columns match `_piName`.
   - **Fix:** Deduplicate `(provider, model)` in `piListedModels` with a `Set<String>` and skip header/separator lines by checking `cols[0].toLowerCase() == 'provider' || RegExp(r'^-+$').hasMatch(cols[0])`.

10. **Low** — [`core.dart:90-97`] & [`core.dart:791-793`]
    - **Scenario:** `_piOnlineNow()` caches `pi --list-models` for 1 minute. If the user opens Ask AI, selects an online `pi` model, takes >1 minute to write their question, and `pi --list-models` times out (5s) when `_askRun` refreshes `_piOnlineNow()`, `_piOnline` is overwritten with `const []` and `_askRun` fails with `no_helper`.
    - **Fix:** Keep the previous non-empty `_piOnline` list when a refresh returns empty (or while `session.which('pi') != null`), or accept a model in `_askRun` if it was in the last `ask.helpers` response.

11. **Low** — [`my_application.cc:85-93`] & [`my_application.cc:103-126`]
    - **Scenario:** The private `wl_event_queue` + `wl_proxy_create_wrapper` pattern in [`ensure_grab_manager`] and moving `self->grab_manager` back to the default queue via `wl_proxy_set_queue(self->grab_manager, nullptr)` before creating grabs and destroying `queue` is valid libwayland usage (`cleared` will still arrive on GTK's main loop). Minor edge case: in [`registry_global`], if the compositor advertises `hyprland_focus_grab_manager_v1` more than once, `self->grab_manager` is overwritten without destroying the first proxy (leaving the first proxy attached to `queue` when `wl_event_queue_destroy(queue)` runs).
    - **Fix:** Guard `if (self->grab_manager == nullptr && strcmp(interface, "hyprland_focus_grab_manager_v1") == 0)` in `registry_global`.

12. **Low** — [`ask_page.dart:54`] & [`ask_page.dart:93-98`]
    - **Scenario:** `hiddenNow` in `_AskPageState` overrides `app['hidden']` for the lifetime of `AskPage` and is not cleared when `_ask` runs a new query (though `_setHidden` already awaits `_load()`, which refreshes `widget.apps` (`byKey`) in place).
    - **Fix:** Clear `hiddenNow.clear()` inside `_ask()` when starting a new query (or once `await widget.actions.setHidden(...)` completes, since `widget.apps[key]['hidden']` is already updated by `_load()`).


---

## Claude's check (2026-11-03), each finding against the code

| # | Verdict | Change |
|---|---|---|
| 1 | Real race (not reproduced in 10 runs; fits an earlier unexplained flaky run): the question was written to Hermes's stdin, which it never reads. | Output read from the start; stdin only for helpers that read it; a broken pipe is no error by itself; stdin closed without waiting. |
| 2 | **False for the real app** (and the cited `terminal_busy`/sed/awk code does not exist): with pty.dart, setsid does not fork; the command is a direct child, session leader on a pts (checked with the real PtySession). | Hardened anyway: every descendant (child or grandchild) is checked; tested with a grandchild. |
| 3 | Confirmed. | `models` must be a list. Test. |
| 4 | Confirmed. | Indentation by blocks (any width, tabs), comments after quoted and unquoted values, https default 443, provider name checked. Test. |
| 5 | Confirmed. | `systemctl --user start --no-block` with a 10 s bound; the page shows the core's reason. Test. |
| 6 | Confirmed, cannot be avoided: Hermes's `-z` takes the prompt only as an argument (no stdin or file option). | Said in Hermes's helper note. |
| 7 | Confirmed (Low in practice). | Ctrl+Enter does nothing while asking or at 2000 characters. |
| 8 | Confirmed. | docs/protocol.md: ask.helpers and ask.run updated (apps.close already had `address`). |
| 9 | Confirmed. | Duplicates and the header dropped. Test. |
| 10 | Confirmed. | A failed `pi --list-models` keeps the last list. |
| 11 | **False**: registry_global_cb already binds only while `grab_manager == nullptr`. | none |
| 12 | Confirmed (cosmetic). | A new question forgets earlier Hide/Unhide clicks. |
