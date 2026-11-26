import 'dart:io';

import 'package:maprisma_core_kit/files.dart' show PrivateFolder;
import 'package:maprisma_core_kit/screenshot.dart' as kit;
import 'package:path/path.dart' as p;

export 'package:maprisma_core_kit/files.dart' show PrivateFolder, debugFailWriteAfter, makePrivateFolder;
export 'package:maprisma_core_kit/screenshot.dart' show homeShort, saveScreenshotNote, screenshotNoteLimit;

/// The pictures folder (XDG_PICTURES_DIR from user-dirs.dirs, read bounded and never through a
/// link, else ~/Pictures) with "MaprismaLauncher" in it.
String screenshotFolder([Map<String, String>? environment]) =>
    kit.screenshotFolder(appName: 'MaprismaLauncher', environment: environment);

/// `<date>-<time>` of a picture's name: 2026-11-03-08-26-31.
String screenshotStamp(DateTime at) {
  String two(int n) => '$n'.padLeft(2, '0');
  return '${at.year.toString().padLeft(4, '0')}-${two(at.month)}-${two(at.day)}'
      '-${two(at.hour)}-${two(at.minute)}-${two(at.second)}';
}

/// `maprisma-launcher-<stamp>.png`, or -2, -3 … when a picture or a note already has that name in
/// the folder (also a link that points nowhere).
String freeScreenshotName(PrivateFolder folder, String stamp) =>
    kit.freeScreenshotName(folder, stamp, filePrefix: 'maprisma-launcher');

/// The PNG into a new file of its own in [folder]; returns its path.
String saveScreenshot(String folder, List<int> png, {DateTime? at}) {
  final where = PrivateFolder.open(folder);
  try {
    final name = freeScreenshotName(where, screenshotStamp(at ?? DateTime.now()));
    where.writeNew(name, png);
    return p.join(folder, name);
  } finally {
    where.close();
  }
}

/// Into the folder chosen in Settings; one that cannot be used (missing rights, not yours, open to
/// others) loses no picture: it goes to the default folder.
String saveScreenshotTo(String? chosen, String fallback, List<int> png, {DateTime? at}) {
  if (chosen != null) {
    try {
      return saveScreenshot(chosen, png, at: at);
    } on FileSystemException {
      // the default folder below
    }
  }
  return saveScreenshot(fallback, png, at: at);
}
