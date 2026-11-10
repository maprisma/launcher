# Maprisma Launcher

The Flutter app of Maprisma Launcher (its core: `../packages/maprisma_launcher_core`).

## F12: a screenshot with a note

F12 (without Ctrl, Shift, Alt or Super) saves a picture of the launcher's own window, dialogs
included, and then asks for an optional note about what is wrong (Done, Enter, Esc or a click
beside the dialog keep what you typed). Settings › Screenshots turns the key off and picks the folder.

- Where: `~/Pictures/MaprismaLauncher` (the pictures folder of `user-dirs.dirs` when it names one),
  or the folder chosen in Settings; a chosen folder that cannot be used sends the picture to the
  default one. Names: `maprisma-launcher-<date>-<time>.png`, the note next to it as `.txt`.
- Private: only a real folder of yours that others cannot write to is used (made `0700` when
  missing, checked on its opened handle, never through a link). Every picture and note is a new
  file only you can read (`0600`), never written over an older one, written completely and synced,
  or removed again. Notes are at most 4000 characters.
- Nothing is uploaded and no screenshot program is started: the window draws itself into the
  picture. F12 does nothing while the app's terminal runs a command (sudo may be asking for the
  password).

## Settings › Corners

Like windows (the desktop's window rounding), Slightly rounded (6 px), Rounded (12 px) or Square.
The window, cards, folders, dialogs and pop-up menus take the full radius; buttons, choice boxes,
fields, list rows, chips and tooltips at most 8 px; check boxes, slider tracks, progress bars and
small tags at most 4 px. Square squares all of them, and the slider keeps a small square knob.
Older settings files (`windows`, `rounded`, `square`) keep working.
The dock keeps rounded corners even with Square, and keyboard keys on the Shortcut page keep
their own shape.
