### Repository URL

https://github.com/maprisma/omarchy-maprisma-launcher

### Category

Productivity

### Tags

launcher, ai, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

A bar icon for Maprisma Launcher, a separate desktop app (Flutter, MIT, github.com/maprisma/launcher): all
apps in one theme-aware window, groups and folders, sizes and updates, install/remove through the package
managers the user allows, an optional AI helper.

The plugin itself is `BarWidget.qml` plus `maprisma-launcher-toggle` (POSIX sh, 20 lines): a click runs
`maprisma-launcher --toggle` when the app is on PATH; otherwise a plain-text `notify-send` note says how to
install it. The plugin installs nothing, starts no service, makes no network request, reads and writes no
files and takes no input. No capabilities beyond starting the user's own installed app.

Dependency outside the standard install (expected `manual-setup`): the app, from the AUR
(`maprisma-launcher-bin`, prebuilt release tarball with SHA-256) or the AppImage from the GitHub release.
The app's own install/remove features run package-manager commands only after a review the user confirms,
in the user's terminal, with the package as a positional argument; they live in the app, not in this plugin.

Tests: `sh tests/test-toggle.sh` (fake app, fake notifier). preview.png: real screenshots of the app on
Omarchy (empty workspace), composed as described in the README.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
