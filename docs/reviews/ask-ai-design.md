# Design Review: Ask AI in App Manager (Antigravity, 2026-11-03)

Proposal reviewed: `/mnt/Data/Projects/appmanager/docs/proposals/ask-ai.md:1-57`
Project plan: `/mnt/Data/Projects/appmanager/docs/plan.md:1-129`

---

## Executive summary: what I agree with and what I would change in Claude's first take

Ask AI is a **headline differentiating feature** of App Manager designed for **new, inexperienced Linux users** who do not know Linux package names (`gimp`, `kdenlive`, `evince`, `org.gnome.Loupe`) or command-line flags. Unlike power-user launchers (Rofi, Walker, Albert, Vicinae) that only launch known names, or traditional software centers (GNOME Software, KDE Discover) where literal keyword search misses apps whose descriptions don't repeat the query word, App Manager's Ask AI acts as a **safe, beginner-friendly app advisor and installer**, with **voice dictation** built in.

Claude's safety boundary—**two layers** (deterministic package/app operations in the core, Ask AI translating natural language into checked proposals over real candidates) and **never letting the AI write a command line** (`docs/proposals/ask-ai.md:32-38`)—is right and matches Maprisma's `SmartProposals` design (`packages/maprisma_core/lib/src/smart_card.dart:24-30, 1498-1543`).

I would change **eight concrete points** in Claude's first take:

1. **Always show the Ask AI button in the header — and make the "no AI set up yet" page a friendly onboarding guide for beginners.** Never hide the Ask AI symbol. When an online or local agent is ready, show its icon (`agent_catalog.dart:179-224`); when none is installed or signed in yet, keep the Ask AI button visible in the header (`docs/proposals/ask-ai.md:9-10, 43-44`) and open the Ask AI page with a clear, plain-language beginner guide explaining how to enable real AI help (1-click terminal setup/sign-in for `claude`, `gemini`, `codex`, `agy`, or opening Maprisma for a free local LLM), plus a direct package search bar that works immediately even before AI is configured.
2. **App discovery & suggestions for users who don't know which app they need (`search(queries)` → verify → `picks`).**
   - A single-step `install(manager, package)` (`docs/proposals/ask-ai.md:36`) fails because an LLM without real repository results will hallucinate package names.
   - Equally important, a naive single-keyword `search(query)` (e.g. `pacman -Ss "photo editor"`) **also fails on Linux** because `pacman -Ss` ANDs words against short `%DESC%` strings: in Arch's repo, `gimp`'s description is `"GNU Image Manipulation Program"` (does not contain `"photo"` or `"editor"`!), and `kdenlive` does not contain `"cut"` or `"holiday"`.
   - Therefore, in **Call 1**, when a user describes a problem (*"I want to edit photos"*, *"cut a holiday video"*, *"read PDFs"*), the AI should:
     1. Check if an **already-installed app** in `facts['apps']` solves the task (so we can suggest opening what they already have!), and
     2. Return `{"action": "search", "queries": ["gimp", "krita", "darktable", "pinta", "photo"]}` — up to **5 concrete app/package names or AppStream keywords**.
   - The core queries the enabled package managers for those terms, deduplicates real matches, and in **Call 2** (`smartPicksPrompt`, `smart_card.dart:229-239`) the AI picks the best 1–3 verified candidates and writes a **beginner-friendly `reason`** in the user's language explaining *what each suggested app is best for* (e.g. simple vs. pro, already installed vs. new install).
3. **Include Voice Dictation in Ask AI and Settings (from Maprisma Task 024).**
   - Reuse Maprisma's `DictationService` (`packages/maprisma_core/lib/src/dictation.dart:1-1518`), `DictationControls` (`flutter_app/lib/dictation_card.dart:1-850`), and task 024 design (`docs/tasks/024-dictation.md:1-36`).
   - Gives beginners a microphone button right inside the Ask AI prompt field across all 4 tiers (`omarchy` Voxtype/Superwhisper, offline `whisper.cpp`, `local` LLM audio model, `online` OpenAI/Groq API), and **shares existing downloaded Whisper models** from `~/.local/share/maprisma/whisper/models`, `~/.local/share/voxtype/models`, and `~/.cache/whisper` (`dictation.dart:14, 80-81`) so models are never downloaded twice. Note that `config.dart:156-158` already uses `F12` for screenshots so `F9` stays free for Omarchy push-to-talk (`docs/tasks/024-dictation.md:31`).
4. **Batch removals ("remove everything from Flatpak I never opened") need multi-candidate proposals and honest scope limits.** Linux does not track "never opened" across all historical desktop launches; App Manager only tracks `seen.json` (`packages/appmanager_core/lib/src/newapps.dart:1-85`), current running state (`running.dart:1-118`), and whether `~/.var/app/<flatpak-id>` exists. Also, `uninstall_plan` (`reference/gnome-launcher/details.py:276-308`, `packages/appmanager_core/lib/src/updates.dart:143-169`) currently only knows `pacman` and `flatpak`, not `apt`, `dnf`, `zypper`, or `snap`.
5. **Privileged vs. unprivileged execution per action and desktop:**
   - **System packages (`pacman`, `yay`/`paru`, `apt`, `dnf`, `zypper`, `snap`)**: always run in an external terminal (`desktops.dart:66-83`), never via `pkexec` or `PackageKit`/`pkcon`.
   - **Flatpak**: do **not** hardcode `--user` blindly; run `flatpak install` in the terminal (or match the remote's scope, user vs. system) so progress and permissions are visible.
   - **CosmicDesktop.systemUpdate() and `cosmic-term` are missing** in `packages/appmanager_core/lib/src/desktops.dart:362-424` and `launch.dart:12-25` / `origins.dart:155-158` (whereas `docs/plan.md:45` specifies `cosmic-term, cosmic-store`).
6. **AUR safety needs four hard guards:** (a) the AUR checkbox is **unchecked by default** even when `yay` or `paru` is installed; (b) official repository matches (`pacman`) always rank above AUR matches; (c) AUR candidates show a prominent warning badge + maintainer/vote metadata and a **"View PKGBUILD"** button on the review card; and (d) the terminal runs `yay`/`paru` **without `--noconfirm`**.
7. **Card sizes and descriptions must not spawn `pacman -Qi` per app.** `reference/gnome-launcher/details.py:115-138` and `packages/appmanager_core/lib/src/origins.dart:234-279` already read `/var/lib/pacman/local/*/desc` directly from disk in milliseconds, and `updates.dart:69-85` already batches `pacman -Qo -- <all /usr/*.desktop paths>` into **one** subprocess call. Also fix `scanDesktopEntries` (`desktop_entries.dart:371, 391`) to use `localeString` (`desktop_entries.dart:269-276`) for localized `Name`/`Comment` and fall back to `GenericName` and package `%DESC%`.
8. **Shared AI runtime state with Maprisma:** Read Maprisma's existing agent adapters, `~/.local/state/maprisma/smart-helpers.json`, `~/.config/maprisma/settings.json` (`local_helper`), and Whisper model folders, and write token runs to `~/.local/state/omarchy-plugin-ai/runs.json` (`system_help.dart:191-261`).

---

## What exists in the wider Linux / desktop ecosystem (and how we do it better)

Looking at existing approaches across Linux and macOS:

1. **Command-palette launchers (Raycast AI on macOS; Vicinae, Walker, Albert, Anyrun on Linux):**
   - Raycast and Linux clones like Vicinae (`github.com/vicinaehq/vicinae`) or Walker add AI chat extensions, but they treat AI as a **free-form chat or shell-command generator** separate from package management. Asking them to install an app either pastes a raw shell snippet (`sudo pacman -S ...`) generated by the LLM or requires a separate store extension.
   - **Our advantage:** In App Manager, Ask AI is wired directly into the core's verified package-manager adapters and installed-app catalog. The AI never writes a shell command; it selects real packages verified on this machine and opens a structured **Review** card showing size, package manager, origin, and dependencies.
2. **Linux Software Centers (GNOME Software, KDE Discover, COSMIC Store, Bazaar) & Flathub / AppStream:**
   - Desktop stores index **AppStream metadata** (`/usr/share/swcatalog/xml/*.xml.gz` or `/usr/share/app-info/xmls/` and Flathub's AppStream catalog), which includes `<name>`, `<summary>`, `<description>`, `<categories>`, and `<keywords>`.
   - However, classic software center search is still **lexical**: if a new user types *"I want to cut a clip from my vacation video"* or *"something to open a .psd file"*, `pacman -Ss` or `flatpak search` returns nothing because no package summary contains the phrase `"vacation video"`.
   - Flathub recently experimented with natural-language/semantic search on its website, and Linux AI assistants like Newelle let users chat with an LLM, but neither knows **both** what is already installed across all package managers on the user's PC (`pacman` + `Flatpak` + `AppImage` + `Snap` + web apps) **and** which package managers the user allows.
   - **Our advantage:** By combining **LLM intent expansion** (mapping *"cut a vacation video"* → concrete Linux app candidates `["losslesscut", "kdenlive", "pitivi", "handbrake", "video"]`) with **local deterministic verification** across the user's checked package managers (`pacman`, `flatpak`, `apt`, `dnf`, `zypper`, AUR) plus checking **already-installed apps first**, a complete beginner gets friendly, accurate app recommendations that are guaranteed to exist and install cleanly on their distro.

---

## Answers to the 7 Questions

### 1. Reuse Maprisma's helper code (shared Dart package?) or a copy? What must stay identical (rules, review)?

**Recommendation:** Keep a **focused, byte-aligned copy** of the shared modules in `packages/appmanager_core/lib/src/` (just as `packages/appmanager_core/lib/src/posix.dart:1-188` already mirrors Maprisma's `packages/maprisma_core/lib/src/posix_ffi.dart:1-790`), while **sharing runtime state files on disk** with Maprisma (`~/.local/state/omarchy-plugin-ai/runs.json`, `~/.local/state/maprisma/smart-helpers.json`, `~/.local/share/maprisma/whisper/models`). A cross-repo `path:` dependency in `pubspec.yaml` would break standalone AUR (`appmanager-bin`) and tarball builds (`docs/plan.md:27, 77`).

**Modules to copy/adapt from `/mnt/Data/Projects/maprisma` and what must stay identical:**

| Module | Maprisma source (file & lines) | What must stay identical in App Manager |
|---|---|---|
| **Prompt isolation & untrusted data tags** | `packages/maprisma_core/lib/src/smart_card.dart:55-95` (`_rules`, `_data`, `_request`, `_language`, `_ruleFacts`) | User text wrapped in `<request>…</request>` with `<` replaced by `‹` (`_data` at `smart_card.dart:67`). All desktop-entry names, descriptions, and package search outputs treated as untrusted data. Single JSON object reply. |
| **Guarded tool-less invocation** | `packages/maprisma_core/lib/src/system_help.dart:39-142` (`_closed`, `mcpServers`, `_mcpOff`, `guardBackground`) & `smart_card.dart:1236-1330` (`smartAgent`) | The agent runs with `guardBackground` (all tools off, all MCP servers disabled via `mcp_off`, prompt on `stdin`, `0700` work dir, bounded `runLookUp` at `system_help.dart:305-350`). |
| **Shared run log** | `packages/maprisma_core/lib/src/system_help.dart:191-261` (`runLogPath`, `recordRun`) | Every Ask AI run is appended under an exclusive flock to `$XDG_STATE_HOME/omarchy-plugin-ai/runs.json` (`plugin: 'appmanager'`, `task: 'smart-card'`), so LLM Monitor and Maprisma show App Manager's token usage. |
| **Proposal handle separation** | `packages/maprisma_core/lib/src/smart_card.dart:1498-1543` (`SmartProposals`) & `docs/tasks/004-smart-card.md:17-23` | `SmartProposals.keep` strips `'action'` before returning candidates to the GUI (`smart_card.dart:1520-1526`). The GUI only passes `{proposal, candidate}` to `smart.review` and `smart.run`; proposals expire after 30 minutes (`smartProposalMinutes = 30`). |
| **Specificity-based action rules** | `packages/maprisma_core/lib/src/action_rules.dart:75-124` & `docs/tasks/019-action-rules.md:12-31` | Same specificity scoring (`item: 8, category/manager: 2, action: 1`, tie → `allow`, no match → `deny`), checked both after Call 1 (`smartRefused` at `smart_card.dart:167-184`, before running a search or second LLM call) and at `review`/`run` (`core.dart:3069`). |
| **Voice dictation** | `packages/maprisma_core/lib/src/dictation.dart:1-1518` & `flutter_app/lib/dictation_card.dart:1-850` & `docs/tasks/024-dictation.md:1-36` | Same 4 backend tiers (`omarchy`, `whisper`, `local`, `online`), same stdin-pipe watchdog for `pw-record`/`arecord`/`ffmpeg` (`docs/tasks/024-dictation.md:24`), and shared Whisper model search dirs (`~/.local/share/maprisma/whisper/models`, `~/.local/share/voxtype/models`, `~/.cache/whisper`, `~/.local/share/appmanager/whisper/models`). |
| **Overlay / header / footer look** | `flutter_app/lib/map_smart_card.dart:1-150`, `docs/tasks/014-ask-ai-window.md:11-17`, `docs/tasks/025-common-look-rest.md:8-14` | Header with agent picker + cost hint ("Local, no tokens" vs "Uses plan/tokens") + Back (`Esc`/`Backspace`), `TaskReview` step before any action runs. |

---

### 2. Is the fixed action list enough, or does install need a two-step "search → choose" conversation?

**`install` MUST use the two-call "intent/search → verify in package managers → pick & explain" pipeline inside a single `Ask` click (like Maprisma's `smartModels` at `smart_card.dart:905-1089` and `smartMcp` at `smart_card.dart:530-703`), enhanced for beginner app discovery.**

Why both a single-step `install(manager, package)` AND a single-keyword `search(query)` are not enough for beginners:
1. **Single-step `install(manager, package)` hallucinates:** Without seeing real search output, an LLM guesses wrong package names (`brave` vs `brave-bin` vs `com.brave.Browser`) or picks a manager where the package does not exist.
2. **Single-keyword `search("photo editor")` misses Linux packages:** Because `pacman -Ss` requires all query words to match `%NAME%` or `%DESC%`, `pacman -Ss "photo editor"` misses `gimp` (`"GNU Image Manipulation Program"`), and `pacman -Ss "cut video"` misses `kdenlive` (`"A non-linear video editor..."`).
3. **Beginners often ask *"What app should I use for X?"* when they might already have one installed—or need 2–3 clear suggestions with plain-English pros/cons.**

**How the 2-call pipeline solves both within one `Ask` click (at most 2 LLM calls, 0 tools):**

- **Call 1 (`smartAppsPrompt`):**
  - Receives `facts`:
    - `installed`: compact list of installed apps (`[{id, name, desc, origin, has_update, can_remove}]`),
    - `managers`: the user's checked & installed package managers (`["pacman", "flatpak"]`),
    - `request`: `<request>…</request>`,
    - `language`: user's 2-letter language code (`smart_card.dart:77-84`).
  - Chooses one fixed action:
    - `{"action": "search", "queries": ["gimp", "krita", "pinta", "darktable", "photo"], "already_installed": ["<optional installed app ids that also fit>"]}` — when the user wants to find, get suggestions for, or install an app. The LLM translates the user's natural-language goal into **up to 5 concrete Linux app/package names or single-word category terms**, plus any already-installed app that fits!
    - `{"action": "remove", "apps": ["<exact installed app ids>"]}` — checked against `uninstallPlan` (`updates.dart:143-169`).
    - `{"action": "update", "apps": ["<exact installed app ids>"]}` — checked against `UpdateCheck` (`updates.dart:110-122`); on Arch, native package updates become `update_system` with the no-partial-upgrade explanation (`docs/proposals/ask-ai.md:41-42`).
    - `{"action": "update_system"}` — runs `desktop.systemUpdate()` (`desktops.dart:66-83`).
    - `{"action": "explain", "apps": ["<exact installed app ids>"], "answer": "<plain-language explanation>"}` — when the user asks what an installed app is or which of their installed apps to open for a task (gives an **Open** button and **Details** button).
    - `{"action": "clarify", "question": "<one short question>", "choices": ["<2 to 4 short answers>"]}` — when the request is too broad (e.g., *"I need an editor"* → `["Photos and images", "Videos", "Text or code", "PDF documents"]`). Clicking a choice chip answers without typing.
    - `{"action": "redirect", "hint": "<helpful explanation>"}` — when out of scope or when the needed package manager is unchecked in Settings.
- **Core Search (between Call 1 and Call 2, deterministic, 0 tokens):**
  - Runs bounded searches across the checked package managers for the `queries` terms (`pacman -Ss`, `flatpak search`, `apt-cache search`, `dnf search`, `zypper search`, `yay`/`paru -Ss --aur`), deduplicating results into a verified list of `[{manager, package, name, version, description, aur}]` (capped at 25 results).
- **Call 2 (`smartAppPicksPrompt`):**
  - Receives the user's `<request>` and the **verified search results** (plus any matching `already_installed` apps).
  - Returns `{"summary": "<1-2 friendly sentences advising the user>", "picks": [{"manager": "<manager>", "package": "<exact package>", "reason": "<1 short sentence in simple words why this app fits>"}]}` (up to `smartMaxPicks = 3`, `smart_card.dart:33`).
  - The core validates (`smartPicks`, `smart_card.dart:789-803`) that every `(manager, package)` pair is in the verified search results (or installed apps), enriches it with exact size/dependencies, and returns the proposal handle.

---

### 3. Running installs: terminal only, or also a privileged helper (pkexec, PackageKit/`pkcon`) on GNOME/COSMIC? What is safe on all four desktops?

**Recommendation: Terminal only for all system package managers (`pacman`, `yay`/`paru`, `apt`, `dnf`, `zypper`, `snap`); never `pkexec` and never `PackageKit`/`pkcon`.**

1. **Why not `pkexec`:**
   - In `reference/gnome-launcher/launcher_core.py:1303-1375`, `pkexec` is used only for the opt-in *"Open as administrator"* GUI launch (`ADMIN_FLAG_NAME` in `launcher_core.py:65-150`), while terminal commands use `sudo --` inside a terminal (`launcher_core.py:1315-1331`).
   - Package managers (`pacman`, `apt`, `dnf`, `zypper`) ask interactive questions on a TTY (provider selection, GPG key import, conffile prompts), and AUR helpers (`yay`, `paru`) **refuse to run as root** (`pkexec yay` fails immediately because `makepkg` forbids `EUID == 0`).
2. **Why not `PackageKit` (`pkcon`):**
   - Not installed on Omarchy/Arch by default, discouraged on Arch because it cannot handle interactive pacman questions, and cannot install from AUR.
3. **Why a terminal is safe and consistent on Omarchy, GNOME, COSMIC, and Generic:**
   - `reference/gnome-launcher/launcher.py:3335-3342` (`uninstall_app`) and `packages/appmanager_core/lib/src/desktops.dart:66-83` (`systemUpdate`) already run package actions in the user's terminal.
   - Always pass package names as **positional arguments** (`"$1"` / `"$@"`), never interpolated into the `sh -c` command string, just like `launcher.py:3340-3341`:
     ```dart
     [...terminal, 'sh', '-c', 'sudo pacman -S -- "$1"; echo; read -r -p "Press Enter to close. " _', 'install', pkg]
     ```
   - **Flatpak:** `updates.dart:125-138` and `launcher.py:3343` run `flatpak update/uninstall -y --noninteractive <appId>`. For **new installs** (`flatpak install`), running `flatpak install <remote> <app_id>` in the terminal (or with `--user` when the remote is user-scoped) is safer and friendlier for beginners because large runtime downloads (`org.gnome.Platform`, `org.freedesktop.Platform.GL`) take 1–3 minutes and need visible download progress rather than a silent spinner.
   - **Two COSMIC fixes needed in `appmanager_core`:**
     - Add `cosmic-term` (with `--` separator, as in Maprisma's `packages/maprisma_core/test/agent_detect_test.dart:80-84`) to `launch.dart:12-25` and `origins.dart:155-158`.
     - Add `CosmicDesktop.systemUpdate()` in `packages/appmanager_core/lib/src/desktops.dart:362-424` to check `session.which('cosmic-store')` before falling back to `super.systemUpdate()`, matching `docs/plan.md:45`.

---

### 4. AUR: offer it at all from an AI? Extra warning, PKGBUILD shown before building?

**Yes, offer it when the user checks the AUR box—because popular beginner apps on Arch/Omarchy (`spotify`, `brave-bin`, `visual-studio-code-bin`, `zoom`) are in the AUR—but enforce four strict guards:**

1. **Unchecked by default:** In Settings › Package managers (and on the Ask AI page), official `pacman` and `flatpak` (if installed) are checked by default; the detected AUR helper (`yay` or `paru`, `updates.dart:54-65`) is **unchecked by default** with a subtitle: *"Community build scripts (AUR) — not checked by the distribution."*
2. **Official repos always win:** If both `pacman` (`extra`/`core`) and AUR match a query, the core ranks official repo packages first and marks AUR candidates with `aur: true`.
3. **Warning badge + AUR metadata + "View PKGBUILD" on the Review card:**
   - Show an orange/yellow warning banner on the Review card: *"Community package from the Arch User Repository (AUR). Anyone can upload AUR build scripts."*
   - Display `Maintainer`, `Votes`, `Last Updated`, and `Upstream URL` from `yay -Si` / `paru -Si`, with an extra warning if `Maintainer` is `None` (orphaned).
   - Provide a **"View PKGBUILD"** button on the Review card (`paru -Gp <pkg>` or bounded HTTPS fetch from `https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=<pkg>`, capped at 256 KiB via `bounded.dart`).
4. **Never pass `--noconfirm`:** Run `yay -S -- "$1"` / `paru -S -- "$1"` in the terminal without `--noconfirm` so the helper's own interactive review and `sudo` prompt stay active.

---

### 5. How to detect "Claude / agy / online agent is usable" without spending tokens?

**Always show the Ask AI button in the header (`docs/proposals/ask-ai.md:9-10`), and detect agent readiness with zero token spend using Maprisma's 3-step check:**

1. **Binary & adapter check (0 tokens, pure filesystem):**
   - Reuse `AgentCatalog.detect` (`packages/maprisma_core/lib/src/agent_catalog.dart:246-281`, tested in `agent_detect_test.dart:39-76`) to check `PATH`, `~/.local/bin`, and `~/.local/share/mise/installs` while skipping bare `mise` shims (`agent_catalog.dart:226-244`).
2. **Credential / sign-in presence (`stat`-only + env check, 0 tokens):**
   - Reuse `SetupChecks.credentialsPresent(access)` (`packages/maprisma_core/lib/src/setup_checks.dart:115-130`):
     - Check whether any env var in `access['env']` (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`) is set in `session.environment`, or
     - `stat` whether any credential file in `access['files']` (`.claude/.credentials.json`, `.codex/auth.json`, `.gemini/oauth_creds.json`, etc.) exists in `$HOME` (**never reading the file's secret content**, `setup_checks.dart:7-8, 121-123`), and check `signInExpired` on Omarchy (`setup_checks.dart:132-141`).
   - Also check if Maprisma has a configured local helper (`local_helper` in `~/.config/maprisma/settings.json` + `local_helper.dart:55-132`) and read `~/.local/state/maprisma/smart-helpers.json` (`docs/plan-smart-helpers.md:50`).
3. **Header button & beginner onboarding state when no AI is configured yet:**
   - **When one or more helpers are ready:** The Ask AI header button shows the active agent's icon (`claude`, `agy`, `codex`, `gemini`, or local model icon; on non-Omarchy desktops, Omarchy PUA glyphs fall back to `robotIcon` `\u{f06a9}` as in `agent_catalog.dart:36, 187-196`).
   - **When NO local or online agent is installed/signed in:**
     - **Keep the Ask AI symbol visible in the header** (with a small setup dot or muted badge, never hidden).
     - Clicking it opens the **Ask AI page** in a **friendly Beginner Onboarding view** that explains in simple, non-technical words:
       1. *"To get AI app recommendations and voice help, connect an AI helper:"*
       2. **Free & Private on your PC (No account needed):** If `maprisma` is installed, a **"Set up local AI in Maprisma"** button launches it; otherwise shows how to install a local helper (`ollama` / `llama.cpp`).
       3. **Use an Online AI Agent:** Simple cards for **Claude Code**, **Gemini**, **Codex**, and **Antigravity (`agy`)** showing whether each is *Not installed* or *Installed — needs sign-in*, with a one-click **"Sign in in terminal"** / **"Install"** button.
       4. **Search packages right now (without AI):** Below the setup cards, the package-manager checkboxes and a direct search field remain active so the user can still search and install apps from `pacman` / `Flatpak` immediately!

---

### 6. Size and description: cost of `pacman -Qi` for 100+ apps; cache and refresh rules.

**Do NOT spawn `pacman -Qi` per app (111 subprocesses = ~2 seconds). Use the batch and direct-file-read patterns already in `appmanager_core` and `reference/`:**

1. **Batch `.desktop` → package owner (`1` subprocess for all apps):**
   - `reference/gnome-launcher/updates.py:89-99` and `packages/appmanager_core/lib/src/updates.dart:69-85` (`UpdateCheck.desktopPackages`) already run a single `pacman -Qo -- <all /usr/*.desktop paths>` call (~25 ms total for 111 apps).
2. **Read `/var/lib/pacman/local/<pkg>-<ver>/desc` directly (`0` subprocesses):**
   - `reference/gnome-launcher/details.py:91-102, 115-138` (`parse_desc`, `package_info`) and `packages/appmanager_core/lib/src/origins.dart:234-279` (`OmarchyIndex`) read `/var/lib/pacman/local/` directly from disk.
   - Reading `desc` for the ~80–120 owning packages takes **< 15 ms in pure Dart** with zero subprocesses and yields `%SIZE%` (installed bytes), `%DESC%` (fallback package description), `%VERSION%`, `%INSTALLDATE%`, and `%URL%`.
3. **Batch queries for other package managers:**
   - **Flatpak:** `flatpak list --app --columns=application,size,description` gets size and description for **all** installed Flatpaks in **1** call (instead of `N` calls to `flatpak info`).
   - **dpkg (`apt`):** Read `/var/lib/dpkg/status` (`Installed-Size`, `Description`) or one batched `dpkg-query -W`.
   - **rpm (`dnf` / `zypper`):** One batched `rpm -qf --queryformat '%{NAME}\t%{SIZE}\t%{SUMMARY}\n' <desktop_paths>`.
   - **AppImages / standalone binaries:** `File(program).statSync().size` (`details.py:163-164`).
4. **Fix localized `Comment` and `GenericName` in `desktop_entries.dart`:**
   - `packages/appmanager_core/lib/src/desktop_entries.dart:371, 391` currently reads raw unlocalized `values['Name']` and `values['Comment']`, even though `localeString(group, key, langs)` is already in `desktop_entries.dart:269-276`!
   - Use `localeString` for `Name`, and for `description` fall back in order: `localeString('Comment')` → `localeString('GenericName')` → package `%DESC%`.
5. **Cache & refresh:**
   - Cache `{desktop_path: {package, version, size, pkg_desc}}` in memory and in `~/.cache/appmanager/package-facts.json`, invalidated when the `mtime` of `/var/lib/pacman/local`, `/var/lib/flatpak/app`, `~/.local/share/flatpak/app`, `/var/lib/dpkg/status`, or `/var/lib/rpm/rpmdb.sqlite` changes (same stamp pattern as `OmarchyIndex.index` in `origins.dart:236-243`).

---

### 7. Anything in Uwe's list that should not be done, or done differently?

1. **Add Voice Dictation (like Maprisma Task 024):**
   - Uwe explicitly wants dictation in App Manager's Ask AI just like in Maprisma (`docs/tasks/024-dictation.md:1-36`).
   - Include the mic button in the Ask AI input bar and a Dictation section in Settings (`dictation: true`, `dictation_engine: auto | omarchy | whisper | local | online`, `dictation_whisper_model`), sharing downloaded Whisper models with Maprisma (`~/.local/share/maprisma/whisper/models`) and Voxtype (`~/.local/share/voxtype/models`).
2. **Make "looking for an app without knowing its name" a first-class workflow:**
   - Add clickable **starter suggestion chips** on the Ask AI page for new users (e.g. *"Suggest a photo editor"*, *"Find an app to cut videos"*, *"What apps can I update?"*, *"Which installed app opens PDFs?"*) so an inexperienced user immediately sees what they can ask.
   - When suggesting apps to install, show 1–3 cards with:
     - App name & icon (if available),
     - Plain-language **why this fits** (`reason` from Call 2),
     - Source badge (`System package (pacman)`, `Flatpak`, `AUR — community build`) and download/installed size,
     - **Already installed** badge with an **Open** button when the user already has a matching app!
3. **"remove everything from Flatpak I never opened" (`docs/proposals/ask-ai.md:11-12`):**
   - Linux does not log launches made outside App Manager. Use two real facts: `seen.json` (`newapps.dart:1-85`) and whether `~/.var/app/<app-id>` exists (`has_user_data`).
   - Show a multi-app Review checklist with checkboxes (all checked by default, user can uncheck any) and an honest note: *"These Flatpak apps have no user data in `~/.var/app`."*
4. **Extend `uninstall_plan` beyond `pacman` and `flatpak` (`updates.dart:143-169`, `details.py:276-308`):**
   - Support `apt` (`dpkg -S` → `sudo apt remove`), `dnf` (`rpm -qf` → `sudo dnf remove`), `zypper` (`rpm -qf` → `sudo zypper remove`), and `snap` (`snap remove`) whenever those managers are installed and checked.
5. **Protect default and base-system apps during removal:**
   - If an app has `defaultRoles(app).isNotEmpty` (`origins.dart:112-124`, e.g. default browser or terminal) or belongs to `omarchy-base.packages` (`origins.dart:244`), display a prominent red/yellow warning on the Review card before allowing uninstall.
6. **Keep Card view clean so tiles never overflow (`docs/plan.md:100-101`):**
   - On **Cards** in the main overview (`flutter_app/lib/overview.dart`), show: **App Name** (1 line), **short description** (1–2 lines, `TextOverflow.ellipsis`), and a compact **size + origin pill** (`142 MB · Flatpak`). Keep full multi-row metadata (paths, command, install date, URL, reverse dependencies) on the **Details** page (`reference/gnome-launcher/launcher.py:4502-4532`).
