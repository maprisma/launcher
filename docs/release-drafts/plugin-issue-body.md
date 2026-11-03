### Repository URL

https://github.com/maprisma/omarchy-maprisma-launcher

### Category

Productivity

### Tags

launcher, ai, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

A bar icon and shell companion for **Maprisma Launcher**, a separate desktop application for Omarchy (Flutter + Dart core, MIT, `https://github.com/maprisma/launcher`):
- **Launch & organise:** narrow list (A–Z, groups, by origin) and wide views (folders, cards with sizes/sources, icons, interactive 3D cube); open floating or on a workspace, switch to or close windows, auto-discover CLI coding agents, and run an optional GTK layer-shell dock.
- **Ask AI:** optional package discovery and management via Claude Code, Codex, Antigravity, Hermes, `pi`, or local LLMs on the user's PC (Ollama / `llama.cpp`), locked down without tools; every package action is reviewed first and runs in the terminal.
- **Global shortcuts & key map:** assign 1-step or 2-step Hyprland shortcuts with a live keyboard map coloured by owner (free, user bindings, Omarchy defaults) and safe one-click rebind.
- Part of the upcoming **Maprisma** AI management suite for Omarchy.

The plugin itself is only `BarWidget.qml` plus `maprisma-launcher-toggle` (POSIX `sh`, 24 lines):
- Clicking the bar icon runs `maprisma-launcher-toggle`, which executes `maprisma-launcher --toggle` when the app is on `PATH`; otherwise a plain-text `notify-send` notification shows how to install the app.
- On shell startup (`Component.onCompleted`), `BarWidget.qml` runs `maprisma-launcher-toggle --dock`, which starts `maprisma-launcher --dock` if the app is installed (exits immediately when the dock setting is off, which is the default).
- The plugin installs nothing, starts no background service when the dock is off, makes no network requests, reads/writes no files, and takes no user input.

Dependency outside the standard install (expected `manual-setup`): the `maprisma-launcher` app, installed from the AUR (`maprisma-launcher-bin`, prebuilt release tarball with SHA-256) or the AppImage from the GitHub release (plus optional `gtk-layer-shell` package if the user enables the dock). All package-manager and Hyprland shortcut features live in the external app, not in this plugin.

Tests: `sh tests/test-toggle.sh` (mock app and mock notifier). `preview.png`: composite of 4 real screenshots of the app on Omarchy (Folders + window menu, Ask AI with local/cloud models, Global Shortcuts + owner-coloured key map, 3D Cube + optional dock).

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
