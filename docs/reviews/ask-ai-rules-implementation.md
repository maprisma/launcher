# Launcher Ask AI rules implementation — 2026-11-14

Implemented on the already checked-out `ask-ai-rules` branch. No commit, push,
installation or publication. Settings' full shared contract, review notes,
`rules.dart`, `shared_helper.dart` and libc locking implementation were read.
Tests use temporary HOME/config/state directories and synthetic commands/data.

## Implementation and decisions

- Core owns random 192-bit proposal ids in session memory. Install picks carry
  `proposal`; installed-app answers carry `proposals` indexed by app key; update
  answers additionally carry `system_proposal`. Ids bind action, exact target and
  source. They expire when the core is disposed/restarted. Manual calls omit ids.
- All execution routes in the Launcher contract table accept provenance. Guards
  reject unknown ids, changed actions/targets/sources and current policy denial
  as `ask_ai_blocked`, with the contract's exact message and a blocked log entry.
  Guards run before preparation and again at asynchronous commit boundaries:
  terminal command preparation, uninstall package lookup, shortcut snapshots and
  backend preparation, and verified AppImage download before installed-file swaps.
- For a batch uninstall terminal command, `proposal` is a map of app key to that
  target's proposal id. All requested targets are checked before preparing the
  combined plan. Only the chosen manager group's actual targets are logged after
  preparation. This preserves the combined dependency calculation while keeping
  individual operations bound and individually correlated in the shared log.
- The GUI fetches `ask.rules` for each Ask answer and carries ids in copied app
  data through shared callbacks, install reviews, shortcut editors, batch plans,
  embedded terminals and detached-terminal fallbacks. Disabled operations retain
  an actual disabled button with the translated contract text and a Settings
  link. Shortcut answers remain readable with mutation controls disabled.
  `ask.settings` starts `maprisma-settings --page ai` detached, as argv, without a
  shell. Existing reviews remain. The core independently rechecks current rules
  even when a review or result was rendered before a switch changed.
- Source switches never filter discoveries. Downloads denial suppresses both
  Ask-only local scan paths and blocks local proposals at execution, including
  already-cached reviews. Manual discovery and local installation stay available.
- Shared helper writes use the existing persistent `settings.lock`, libc
  `flock(LOCK_EX)`, locked read/modify/write, private O_EXCL temporary files,
  fsync and atomic rename. Existing broken, oversized or unreadable shared files
  are refused rather than rebuilt. Unrelated settings survive concurrent writers.
- Log records use exactly the shared JSON field names and timestamp/result
  conventions, with proposal id as `op`. Persistent `actions.lock` serializes
  appends and rotation. Direct operations log done/failed; terminal handoffs log
  started. Observed embedded-terminal completion logs done/failed once; closing a
  running terminal logs cancelled. Detached terminal outcomes remain started.
  No log is generated for simply displaying a disabled button or cancelling a
  review before execution. Logging failure never blocks or undoes execution.
- Log I/O uses no-follow, non-blocking descriptors checked for regular type and
  owner; directories are real, owned and private. Non-regular locks are refused
  without hanging. Appends loop over partial writes, and bounded tail reads keep
  rotation/readers within 1 MiB. Rotation retains the newest 500 complete lines
  above 1000 lines or 1 MiB, with an exclusive synced temp under the stable lock.

## Contract deviations and reference differences

No intended deviation from the shared contract. Two details differ from the
current Settings reference implementation in order to follow the written contract:

1. Explicit JSON nulls are restrictive: `ask_ai: null`, null level and null
   actions/sources/folders maps are malformed. The reference treats these nulls
   like missing keys. Missing keys still have the shared defaults. This difference
   is covered by tests and documented in protocol.md; no shared file format changes.
2. The reference's log data/temp opens and settings temp open use ordinary Dart
   file APIs in places. Launcher uses libc no-follow/owner checks and O_EXCL
   creation, plus bounded owned-descriptor log reads, to meet the contract's
   security requirements. Lock names, flock primitive, persistent-lock protocol,
   shared settings layout and JSON line schema remain compatible.

The batch proposal map is an API representation of the contract's requirement
that every target in a batch retain its own id; it adds no new shared-file format.

## Changed files

Core (under `packages/maprisma_launcher_core/`):

- `lib/src/ask_ai_rules.dart`: new restrictive reader, decision and compatible log.
- `lib/src/core.dart`: proposal registry, guarded routes, rules/settings routes,
  Downloads scope, terminal result correlation and execution rechecks.
- `lib/src/ai_choice.dart`: locked helper writer and bounded shared-object reader.
- `lib/src/posix.dart`: private append/tail operations and checked non-blocking locks.
- `lib/src/appimage_updates.dart`: policy recheck before replacing installed files.
- `lib/src/shortcut_service.dart`, `lib/src/shortcuts.dart`: policy callback after
  asynchronous preparation and before desktop writes.
- `lib/maprisma_launcher_core.dart`: exports rules API.
- `test/ask_ai_rules_test.dart`, `test/fixtures/ask_ai_writer.dart`: ten new tests,
  including actual core-issued ids, source/target/action rejection, all boundaries,
  cached local reviews, manual scope, async revocation, blocked/done/failed records,
  two concurrent processes, private modes, rotation, FIFO locks and symlinks.
- `test/ai_helpers_test.dart`, `test/ask_ai_test.dart`: update expectations for the
  required persistent lock file and random proposal metadata.

GUI (under `flutter_app/`):

- `lib/ask_page.dart`: current rules, disabled controls/settings links and provenance.
- `lib/apps_page.dart`: ids through mutations, batch terminal requests and fallback.
- `lib/install_page.dart`: id through install review and both terminal paths.
- `lib/shortcut_page.dart`: id through editor changes and readable read-only lists.
- `test/ask_page_test.dart`: disabled action/link, readable denied shortcut lists,
  callback provenance tests, and updated system callback signature.
- `assets/translations/{de,es,fr,it,nl,pl,pt}.json`: generated translations.

Other files: `i18n/extra.json` (two texts in all seven languages),
`docs/protocol.md` (routes, params, mapping, log and file protocols), `docs/plan.md`
(progress), and this report.

## Validation

SDK: `/mnt/Data/flutter` (not on the session PATH).

| Check | Result |
|---|---|
| Full core `dart test` | 195 passed, 6 skipped, 3 socket-blocked failures; all ten new rules tests passed |
| Full GUI `flutter test --no-pub` | Attempted: all 19 test files fail to load because the Flutter runner cannot bind 127.0.0.1; no widget tests execute |
| GUI `dart analyze` | No issues found |
| Core `dart analyze` | No errors or warnings; style-level informational lints only |
| `python3 -I -B tools/i18n.py` and `--check` | 479 texts/language; 0 missing across all seven languages |
| `git diff --check` | Passed |

The three core failures are exclusively `SocketException`, OS error 1,
Operation not permitted:

- `test/ask_ai_test.dart`: pi local models after local server answers
  (loopback TCP server).
- `test/ask_ai_test.dart`: pi online models and Hermes (loopback TCP server).
- `test/oracle_dock_test.dart`: HyprEvents reads a socket in lines and drops a
  huge one (Unix-domain server).

The six existing live-machine oracle skips retain their default opt-in behavior;
`MAPRISMA_LIVE_TESTS=1` was not set.

The normal Flutter wrapper first failed trying to update the read-only SDK cache.
The suite was then actually invoked through the already-cached tool:

```sh
FLUTTER_ALREADY_LOCKED=true /mnt/Data/flutter/bin/cache/dart-sdk/bin/dart \
  /mnt/Data/flutter/bin/cache/flutter_tools.snapshot test --no-pub
```

That reaches the test runner but every file is blocked at its loopback test-server
startup. The new GUI tests therefore still need execution outside this sandbox;
static analysis validates their types and the GUI wiring here.
