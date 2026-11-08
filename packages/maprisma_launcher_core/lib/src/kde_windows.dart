/// KDE Plasma's windows through KWin scripts (kwin_bridge.dart), in the
/// shape COSMIC's helper gives: matching and states are shared.
library;

import 'package:dbus/dbus.dart';

import 'cosmic_windows.dart';
import 'desktop_entries.dart';
import 'kwin_bridge.dart';

final class KdeWindows extends ToplevelWindows {
  KdeWindows(this.session);
  final Session session;
  KWinBridge? _bridge;

  /// The session bus of the Session's environment only (tests have none).
  KWinBridge? get bridge {
    if (_bridge != null) return _bridge;
    final address = session.environment['DBUS_SESSION_BUS_ADDRESS'];
    if (address == null || address.isEmpty) return null;
    final runtime = session.environment['XDG_RUNTIME_DIR'];
    try {
      return _bridge = KWinBridge(DBusClient(DBusAddress(address)),
          scriptDir: runtime == null || runtime.isEmpty ? null : '$runtime/maprisma-launcher');
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _wm(List<String> args) async {
    final b = bridge;
    if (b == null) return null;
    try {
      // No outer timeout: each bridge request has its own deadline from the
      // call and is never run after it (a late close or focus cannot happen).
      return await kdeWm(b, args);
    } on Object {
      return null;
    }
  }

  @override
  Future<List<Map>?> clients() async {
    final r = await _wm(['windows']);
    final list = r?['windows'];
    if (list is! List) return null;
    return list.whereType<Map>().where((w) => CosmicWindows.validId(w['id'])).toList();
  }

  @override
  Future<bool> focus(String id) async => CosmicWindows.validId(id) && (await _wm(['activate', id]))?['done'] == true;

  @override
  Future<bool> closeWindow(String id) async => CosmicWindows.validId(id) && (await _wm(['close', id]))?['done'] == true;

  Future<void> dispose() async => _bridge?.dispose();
}
