# Maprisma Launcher: notes for agents (Claude, Antigravity)

- **Installing for Uwe to test: only `tools/install-local`** (builds the release, stops every running copy
  by its real program path, refuses while the app's terminal runs a command, unpacks into a fresh folder and
  swaps it in, restarts the dock if it ran). `--no-build` uses the last `dist/` tarball; `--force` also ends a
  running terminal command.
  - **Never** `tar --overwrite`, `cp` or `install` over `~/.local/lib/maprisma-launcher`: the running app maps
    `lib/libapp.so` from there, and changing it under it crashes it (two SIGSEGVs on 2026-11-03).
  - `pkill`/`killall maprisma-launcher` match nothing: the process name is cut to `maprisma-launch`.
- Tests write no real config: use temp HOME/config folders (see the existing tests). Before a commit, the
  tests of the changed area; the full suites (`dart test` in packages/maprisma_launcher_core, `flutter test`
  in flutter_app, `python3 -I -B tools/i18n.py --check`) before publishing.
  Live-machine oracle checks run only with `MAPRISMA_LIVE_TESTS=1`; the default suite uses synthetic data or skips them.
- New interface texts: `tr()`, translations in `i18n/extra.json` (7 languages), then `python3 -I -B tools/i18n.py`.
- Every core route is listed in `docs/protocol.md`; progress in `docs/plan.md`; reviews in `docs/reviews/`.
- Nothing is pushed or published without Uwe's OK.
