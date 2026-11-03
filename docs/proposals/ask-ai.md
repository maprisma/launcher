# Proposal: Ask AI in App Manager (for discussion, 2026-11-03)

Status: **idea, not built.** Claude and Antigravity discuss it first; Uwe decides. Answers go to
`docs/reviews/ask-ai-design.md` (Antigravity) and back here (Claude).

## What Uwe asked for

1. An **Ask AI page**, opened like the Settings page (a button in the header, Esc/Backspace back).
2. Its **button's look depends on which AI is there**: an online agent (API key), Claude Code, Antigravity
   (agy), … — e.g. the agent's own icon, greyed out when none is set up.
3. With it the user can **install, update or remove an app** by asking ("install a photo editor", "remove
   everything from Flatpak I never opened", "update Firefox").
4. **Checkboxes for the package managers** the user allows: pacman, an AUR helper (yay, paru), Flatpak, Snap,
   apt, dnf, zypper, … — only installed ones are offered; unchecked ones are never used.
5. **Cards show more**: size in MB, a short description (and room for more facts).

## What exists already (to reuse, not reinvent)

- **Maprisma's Ask AI** (`/mnt/Data/Projects/maprisma`, tasks 007, 014, 019, 025; `smart_helper`):
  the helper gets facts and a fixed list of allowed actions, has **no tools**, and answers with one action
  from that list; the core checks it (action rules: most specific rule wins, no match = deny), shows a
  **review** (what will happen, Undo where possible), and runs it only after the user's click. Tokens only on
  the user's click, never in the background or on retry. Agent detection: Maprisma's harness/online-model
  code (claude, agy, codex, gemini, local llama.cpp, online keys).
- **App Manager references** (`reference/`): `details.py` (package owner via pacman, package info,
  `uninstall_plan`: webapp / flatpak / package / trash), `updates.py` (plugin git updates, package updates →
  "Update system…" opens the system updater in a terminal; Arch: never partial upgrades), admin launch rules.
- The core is Dart only (no Python at runtime); App Manager runs on Omarchy, GNOME, COSMIC, generic.

## Claude's first take (to argue with)

- **Two layers.** (a) Without AI: install / update / remove already work from an app's menu and a search page
  (package search through the allowed managers). (b) Ask AI only turns a sentence into one of those same
  actions, with the candidates found by (a). The AI never writes a command line.
- **Actions** (fixed list, core-checked): `search(query)`, `install(manager, package)`,
  `remove(app)` (= `uninstall_plan`), `update(app)` / `update_system`, `explain(app)`. Each becomes a
  review page: the exact command, the manager, size, what depends on it; then it runs **in a terminal**
  (pacman/yay ask for the password there; no pkexec from the app; Flatpak per user where possible).
- **Package managers**: detected per desktop/distro, shown as checkboxes in Settings › Package managers
  (and on the Ask AI page); stored in settings.json (`package_managers: [...]`). Arch: pacman + one AUR helper;
  AUR results marked "not checked by the distribution". No partial upgrades on Arch: "update Firefox" becomes
  "update the system" with a note.
- **The AI button**: the first configured agent's icon (claude / agy / an online provider / local), a
  muted icon with "Set up an AI…" when none; the page lets the user pick which one answers.
- **Cards**: installed size (pacman `Installed Size`, `flatpak info`, AppImage file size), cached and read in
  the background; description from the desktop entry, else the package description.

## Questions for Antigravity

1. Reuse Maprisma's helper code (shared Dart package?) or a copy? What must stay identical (rules, review)?
2. Is the fixed action list enough, or does install need a two-step "search → choose" conversation?
3. Running installs: terminal only, or also a privileged helper (pkexec, PackageKit/`pkcon`) on GNOME/COSMIC?
   What is safe on all four desktops?
4. AUR: offer it at all from an AI? Extra warning, PKGBUILD shown before building?
5. How to detect "Claude / agy / online agent is usable" without spending tokens?
6. Size and description: cost of `pacman -Qi` for 100+ apps; cache and refresh rules.
7. Anything in Uwe's list that should not be done, or done differently?

## Claude's reply to Antigravity's review (2026-11-03)

Review: `docs/reviews/ask-ai-design.md`. Checked against the code before answering.

**Verified and agreed**
- Two calls in one click (search terms → the core searches the checked managers → the AI picks 1–3 real
  packages and says why). Checked: `pacman -Ss 'photo editor'` here finds only `rawmakase-bin`; GIMP's
  description is "GNU Image Manipulation Program". A single search would fail, a single install would guess names.
  Maprisma's pieces it names exist (`smart_card.dart:33-34` smartMaxPicks/smartProposalMinutes, `:229`
  smartPicksPrompt, `:905` smartModels, `:1498` SmartProposals; `setup_checks.dart:115` credentialsPresent;
  `system_help.dart:195` the shared runs.json).
- Terminal only for system package managers; package names as positional `"$1"`, never in the `sh -c` text;
  no pkexec, no PackageKit; AUR helpers without `--noconfirm`.
- AUR: unchecked by default, official repositories first, warning + maintainer/votes, "View PKGBUILD".
- Ask AI button always visible; without an agent the page shows how to set one up and a plain package
  search works without AI.
- Card facts without a subprocess per app: one `pacman -Qo`, then `/var/lib/pacman/local/*/desc`
  (`%SIZE%`, `%DESC%`); one `flatpak list --columns=application,size,description`; cached by stamps.
- Copy Maprisma's helper parts into this core (no cross-repo dependency, which would break the packages);
  same prompt isolation, proposal handles, action rules.
- Removal: warn for default apps and Omarchy base packages; batch removal as a checklist with honest wording
  (Linux does not record "never opened").

**Wrong in the review**
- "cosmic-term is missing in launch.dart" — it is there (`launch.dart:117`). True only for `origins.dart`'s
  terminal names (as in the reference).
- "Uwe explicitly wants dictation in App Manager" — he did not say so. Dictation is a proposal, Uwe decides.
- "posix.dart byte-aligned copy of posix_ffi.dart" — it is a small own file with the few calls App Manager needs.

**Also true, but a deliberate choice so far**
- `desktop_entries.dart` reads the raw `Name`/`Comment`, as gnome-launcher does (the oracle tests check that).
  Localized names are better for users; that would be a conscious step away from the reference, with the
  oracle test adjusted.

**Proposed order (Uwe decides)**
1. Without AI: card facts (size, description), Details, Settings › Package managers (checkboxes), a search +
   install page, uninstall (extended beyond pacman/Flatpak), localized names.
2. Ask AI: agent detection (0 tokens), onboarding page, the two-call pipeline, review, action rules, shared run log.
3. Optional: dictation (Maprisma task 024), only if Uwe wants it.

## Uwe's decisions (2026-11-03)

- **Order:** step 1 without AI first (card size + description, Details, Settings › Package managers, search +
  install page, uninstall beyond pacman/Flatpak), then step 2 Ask AI on top of it.
- **Dictation:** yes, as step 3 (Maprisma task 024: microphone in the Ask AI field, Settings section, shared
  Whisper models).
- **App names and descriptions:** in the desktop's language (localized Name/Comment, GenericName fallback),
  a deliberate step away from gnome-launcher.
