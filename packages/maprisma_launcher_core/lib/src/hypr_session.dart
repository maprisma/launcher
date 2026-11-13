import 'dart:io';

/// Whether this is a Hyprland session. XDG_CURRENT_DESKTOP decides when it is set; only without
/// it does HYPRLAND_INSTANCE_SIGNATURE count, and only when that Hyprland's socket is there
/// (`$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`): after a Hyprland session the variable stays
/// in the systemd user environment, so a COSMIC or KDE session sees a stale one.
bool hyprlandSession(Map<String, String> env) {
  final names = [
    for (final t in (env['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase().split(':'))
      if (t.trim().isNotEmpty) t.trim(),
  ];
  // (hyprctl needs the signature: a Hyprland session without it is none for the Launcher)
  if (names.isNotEmpty) return names.contains('hyprland') && (env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty;
  final signature = env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '', runtime = env['XDG_RUNTIME_DIR'] ?? '';
  if (signature.isEmpty || signature.contains('/') || signature.startsWith('.') || !runtime.startsWith('/')) {
    return false;
  }
  return FileSystemEntity.typeSync('$runtime/hypr/$signature/.socket.sock') != FileSystemEntityType.notFound;
}
