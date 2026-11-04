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

The plugin consists of `BarWidget.qml`, `Panel.qml`, `maprisma-launcher-toggle`, and `maprisma-launcher-install`:
- Clicking the bar icon runs `maprisma-launcher-toggle --check`: with the app installed, `maprisma-launcher-toggle` starts `maprisma-launcher --toggle` in a new session; without it, the widget opens its install panel (`Panel.qml`, plain text only). Installation begins only after the panel's Install button is clicked.
- On shell startup (`Component.onCompleted`), `BarWidget.qml` runs `maprisma-launcher-toggle --dock`, which starts `maprisma-launcher --dock` if the app is installed (exits immediately when the dock setting is off, which is the default).
- Capability `installer` (documented in the README): only on the panel's **Install** button, `maprisma-launcher-install` downloads one fixed URL (`https://github.com/maprisma/launcher/releases/download/v0.1.2/Maprisma-Launcher-0.1.2-x86_64.AppImage`) with `curl --proto =https --proto-redir =https --max-filesize --max-time`, keeps it only if its size and SHA-256 match the values pinned in the script, and hard-links it to `~/.local/bin/maprisma-launcher`, which fails instead of replacing anything (an existing file, link or folder stops it). No arguments or administrator rights; normal interruptions clean up the temporary file, while an uncatchable kill may leave a temporary folder. Tests in `tests/test-install.sh`. This is the plugin's only network access. No background service when the dock is off, no text input.

Dependency outside the standard install: the `maprisma-launcher` app, which the plugin's install panel downloads and checks after the Install click (README also shows the manual commands); plus the optional `gtk-layer-shell` package if the user enables the dock. All package-manager and Hyprland shortcut features live in the external app, not in this plugin.

Tests: `sh tests/test-toggle.sh` (mock app and mock notifier) and `sh tests/test-install.sh` (mock download, cancellation and destination race). `preview.png`: composite of 4 real screenshots of the app on Omarchy (Folders + window menu, Ask AI with local/cloud models, Global Shortcuts + owner-coloured key map, 3D Cube + optional dock).

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
