# Publishing Maprisma Launcher (prepared 2026-11-03, nothing published)

Decisions (Uwe, 2026-11-03): name **Maprisma Launcher**; Maprisma's identity (app ID `com.maprisma.Launcher`,
GitHub `maprisma/launcher`); MIT; a **new** marketplace plugin `ubruckhaus.maprisma-launcher` that only
starts the app or says how to install it (no installer capability). The old App Manager plugin
(`ubruckhaus.simple-launcher-for-fools`) stays listed with fixes only.

## What is ready (local, not pushed)

| Part | Where | State |
|---|---|---|
| App | `/mnt/Data/Projects/maprisma-launcher` | version 0.1.0 (`flutter_app/pubspec.yaml`, metainfo release) |
| Release tarball | `tools/build-release.py` → `dist/maprisma-launcher-<v>-x86_64.tar.gz` + `.sha256` | builds |
| AppImage | `packaging/build-appimage.py` (pinned appimagetool 1.9.1 + runtime 20251108) | builds |
| Desktop files | `packaging/share/` (desktop entry validated, metainfo validated) | Maprisma-style icon (grid of apps, 7625e27) |
| AUR | `/mnt/Data/Projects/aur-maprisma-launcher-bin` (PKGBUILD, .SRCINFO) | `makepkg` builds from the local tarball; sha must be set to the uploaded tarball's |
| Plugin | `/mnt/Data/Projects/omarchy-maprisma-launcher` | validate ✓, preflight: no hits, toggle test ✓; no preview.png yet |
| Issue draft | `docs/release-drafts/plugin-issue-body.md` | form text, not posted |

## Before the first release (open work)

1. Done 2026-11-03: marks legend, Details page, Change icon, Maprisma-style icon, VM test (below).
   Global shortcuts + key map: being ported on branch task/shortcuts (worktree maprisma-launcher-shortcuts).
2. Ask AI tried with a real helper (Uwe's click); CachyOS; GNOME and COSMIC (no VMs for them yet).
3. Complete test suites (core: `dart test`, app: `flutter test`, `tools/i18n.py --check`).

## VM test (tools/vm-packages, Omarchy edge VM, throwaway snapshot)

2026-11-03, 0.1.0: `pacman -U` installs (24.7 MiB), `/usr/bin/maprisma-launcher` starts, the plugin's toggle
script opens / hides / shows the window (class com.maprisma.Launcher), `pacman -R` leaves nothing in
/usr/lib, the toggle without the app shows the install note, the AppImage starts. Screenshots in the session's
scratchpad. Run: build the release + AppImage, `makepkg` with the tarball's sha, put the package, the AppImage
and the plugin folder (as `plugin/`) into one folder, `tools/vm-packages <folder>`.

## Release steps (each outward step only with Uwe's OK)

1. Bump the version in `flutter_app/pubspec.yaml` and add `<release version=…>` to the metainfo.
2. `tools/build-release.py`, then `packaging/build-appimage.py`.
3. Test both in the Omarchy edge VM (`~/VMs/omarchy-edge`): install the package, start, toggle, remove.
   Never install it on Uwe's desktop for a test, never run quattro code there.
4. Create the GitHub repos `maprisma/launcher` and `maprisma/omarchy-maprisma-launcher` (public), push,
   tag `v<version>`, upload tarball, AppImage and both `.sha256` files to the release.
5. AUR: set `sha256sums` to the uploaded tarball's, `makepkg --printsrcinfo > .SRCINFO`, push to
   `aur.archlinux.org/maprisma-launcher-bin.git`.
6. Plugin: `preview.png` (skill omarchy-plugin-publishing, references/preview.md: real screenshots, core feature
   first), README check against the app, `bash <skill>/scripts/preflight.sh .`, `omarchy plugin validate .`,
   push.
7. **Codex recheck** of the exact plugin commit until CLEAN (skill rules: at most 4 rounds).
8. Show Uwe the `[Plugin]: Maprisma Launcher` title and `docs/release-drafts/plugin-issue-body.md`, then
   `gh issue create -R omacom/omarchy-plugin-marketplace --title "[Plugin]: Maprisma Launcher" --body-file …`.
9. Expect `manual-setup` (the app is outside the standard install). Watch with the skill's watch-issues.sh.
10. Later, optional: a [Verify] for the old App Manager plugin whose README points to Maprisma Launcher.
