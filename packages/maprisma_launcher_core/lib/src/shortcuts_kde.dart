/// KDE global shortcuts, adapted to the GNOME-shaped settings interface.
library;

import 'dart:convert';
import 'dart:io';
import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'desktop_entries.dart';
import 'protocol.dart' show ServiceError;
import 'shortcuts.dart';

const _qtMods = {
  'SUPER': 0x10000000,
  'SHIFT': 0x02000000,
  'CTRL': 0x04000000,
  'ALT': 0x08000000,
};
const _qtKeys = {
  'Escape': 0x01000000,
  'Tab': 0x01000001,
  'BackSpace': 0x01000003,
  'Return': 0x01000004,
  'KP_Enter': 0x01000005,
  'Insert': 0x01000006,
  'Delete': 0x01000007,
  'Pause': 0x01000008,
  'Print': 0x01000009,
  'Home': 0x01000010,
  'End': 0x01000011,
  'Left': 0x01000012,
  'Up': 0x01000013,
  'Right': 0x01000014,
  'Down': 0x01000015,
  'Page_Up': 0x01000016,
  'Page_Down': 0x01000017,
  'space': 32,
  'minus': 45,
  'equal': 61,
  'bracketleft': 91,
  'bracketright': 93,
  'semicolon': 59,
  'apostrophe': 39,
  'backslash': 92,
  'grave': 96,
  'comma': 44,
  'period': 46,
  'slash': 47,
};

/// A single Qt stroke to GNOME syntax; unknown modifier bits are unsupported.
String? qtToAccelerator(int stroke) {
  final code = stroke & 0x01ffffff;
  if (stroke & ~0x1fffffff != 0) return null;
  String? key;
  if (code >= 65 && code <= 90 || code >= 48 && code <= 57) {
    key = String.fromCharCode(code);
  } else if (code >= 0x01000030 && code <= 0x01000052) {
    key = 'F${code - 0x01000030 + 1}';
  } else {
    for (final e in _qtKeys.entries) {
      if (e.value == code) key = e.key;
    }
  }
  if (key == null) return null;
  return accelerator(
    makeCombo([
      for (final e in _qtMods.entries)
        if (stroke & e.value != 0) e.key,
    ], key)!,
  );
}

/// GNOME syntax to a single Qt stroke. Shifted digits retain their digit code.
int? acceleratorToQt(String text) {
  final combo = parseAccelerator(text);
  if (combo == null) return null;
  final key = combo['key'] as String;
  int? code = _qtKeys[key];
  if (RegExp(r'^[A-Z0-9]$').hasMatch(key)) code = key.codeUnitAt(0);
  final f = RegExp(r'^F([1-9]|[12][0-9]|3[0-5])$').firstMatch(key);
  if (f != null) code = 0x01000030 + int.parse(f[1]!) - 1;
  if (code == null) return null;
  for (final mod in combo['mods'] as List) {
    code = code! | _qtMods[mod]!;
  }
  return code;
}

String? _single(List<int> sequence) {
  final strokes = sequence.where((v) => v != 0).toList();
  return strokes.length == 1 ? qtToAccelerator(strokes.single) : null;
}

/// Action IDs are KDE's four strings: component, action, component label, summary.
abstract interface class KGlobalAccel {
  Future<List<String>> components();
  Future<List<List<String>>> actions(String component);
  Future<List<List<int>>> shortcutKeys(List<String> action);
  Future<void> setForeignShortcutKeys(
    List<String> action,
    List<List<int>> keys,
  );
  Future<void> doRegister(List<String> action);
  Future<void> unregister(String component, String action);

  /// Marks the action present (active) with these keys, as a running app
  /// does for its own shortcuts. A service shortcut registered at runtime is
  /// inactive until then: KDE only fires a pressed key for active ones (it
  /// activates [services] entries itself only when it starts).
  Future<void> setPresent(List<String> action, List<List<int>> keys);
}

/// Short-lived connections avoid retaining a session bus after a settings call.
final class DBusKGlobalAccel implements KGlobalAccel {
  DBusKGlobalAccel(this.session);
  final Session session;
  static const _interface = 'org.kde.KGlobalAccel';
  Future<T> _withBus<T>(
    Future<T> Function(DBusRemoteObject root, DBusClient bus) work,
  ) async {
    final address = session.environment['DBUS_SESSION_BUS_ADDRESS'];
    if (address == null || address.isEmpty) {
      throw StateError('No session bus address');
    }
    final bus = DBusClient(DBusAddress(address));
    try {
      return await work(
        DBusRemoteObject(
          bus,
          name: 'org.kde.kglobalaccel',
          path: DBusObjectPath('/kglobalaccel'),
        ),
        bus,
      ).timeout(const Duration(seconds: 5));
    } finally {
      await bus.close();
    }
  }

  Future<List<DBusValue>> _call(String method, List<DBusValue> args) =>
      _withBus(
        (root, _) async =>
            (await root.callMethod(_interface, method, args)).returnValues,
      );
  @override
  Future<List<String>> components() => _withBus((root, bus) async {
    final response = await root.callMethod(_interface, 'allComponents', []);
    final found = <String>[];
    for (final value in (response.returnValues.single as DBusArray).children) {
      final object = DBusRemoteObject(
        bus,
        name: 'org.kde.kglobalaccel',
        path: value as DBusObjectPath,
      );
      found.add(
        (await object.getProperty(
                  'org.kde.kglobalaccel.Component',
                  'uniqueName',
                )
                as DBusString)
            .value,
      );
    }
    return found;
  });
  @override
  Future<List<List<String>>> actions(String component) async => [
    for (final row
        in ((await _call('allActionsForComponent', [
                  DBusArray.string([component, '', '', '']),
                ])).single
                as DBusArray)
            .children)
      (row as DBusArray).children.map((v) => (v as DBusString).value).toList(),
  ];
  @override
  Future<List<List<int>>> shortcutKeys(List<String> action) async => [
    for (final row
        in ((await _call('shortcutKeys', [DBusArray.string(action)])).single
                as DBusArray)
            .children)
      ((row as DBusStruct).children.single as DBusArray).children
          .map((v) => (v as DBusInt32).value)
          .toList(),
  ];
  @override
  Future<void> setForeignShortcutKeys(
    List<String> action,
    List<List<int>> keys,
  ) async {
    await _call('setForeignShortcutKeys', [
      DBusArray.string(action),
      DBusArray(DBusSignature('(ai)'), [
        for (final sequence in keys) DBusStruct([DBusArray.int32(sequence)]),
      ]),
    ]);
  }

  @override
  Future<void> doRegister(List<String> action) async {
    await _call('doRegister', [DBusArray.string(action)]);
  }

  // setShortcutKeys with SetPresent (2) | NoAutoloading (4).
  @override
  Future<void> setPresent(List<String> action, List<List<int>> keys) async {
    await _call('setShortcutKeys', [
      DBusArray.string(action),
      DBusArray(DBusSignature('(ai)'), [
        for (final sequence in keys) DBusStruct([DBusArray.int32(sequence)]),
      ]),
      const DBusUint32(6),
    ]);
  }

  @override
  Future<void> unregister(String component, String action) async {
    await _call('unregister', [DBusString(component), DBusString(action)]);
  }
}

final class KdeSettings implements KeySettings {
  KdeSettings(this.session, {KGlobalAccel? globalAccel})
    : globalAccel = globalAccel ?? DBusKGlobalAccel(session);
  final Session session;
  final KGlobalAccel globalAccel;
  /// Ours: `maprisma-launcher-<n>-<hash of the command>.desktop`. KDE keeps
  /// the service it first loaded for a component, so a changed command gets
  /// a new file name (a new component), never a rewritten file.
  static final _own = RegExp(r'^(maprisma-launcher-[0-9]+)(?:-[0-9a-f]{8})?\.desktop$');
  String get applications => desktopDirectories(session).first;
  bool _ours(String component) => _own.hasMatch(component);

  /// The custom path of one of ours (the hash is not part of it).
  String _path(String component) => '$customBase${_own.firstMatch(component)![1]}/';

  /// The `maprisma-launcher-<n>` of a custom path of ours.
  String _slot(String path) {
    final name = path.startsWith(customBase) && path.endsWith('/') ? path.substring(customBase.length, path.length - 1) : '';
    if (!RegExp(r'^maprisma-launcher-[0-9]+$').hasMatch(name)) throw ArgumentError.value(path);
    return name;
  }

  /// The component (file) of [path] now, or null.
  String? _existing(String path) {
    final slot = _slot(path);
    final dir = Directory(applications);
    if (!dir.existsSync()) return null;
    for (final f in dir.listSync()) {
      final name = p.basename(f.path);
      if (_own.firstMatch(name)?[1] == slot) return name;
    }
    return null;
  }

  static String _hash(String text) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(text)) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// KDE's bindings carry this schema prefix, so the shared state keeps
  /// where a taken key came from (cleanWhere knows `kde/<component>:<action>`).
  static const schemaPrefix = 'kde/';
  static String _unprefixed(String schema) =>
      schema.startsWith(schemaPrefix) ? schema.substring(schemaPrefix.length) : schema;

  List<String> _id(String component, String key) => [_unprefixed(component), key, '', ''];
  @override
  Future<bool> available() async {
    try {
      await globalAccel.components();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<List<(String, String, String, List<String>)>> bindingKeys() async {
    final found = <(String, String, String, List<String>)>[];
    for (final component in await globalAccel.components()) {
      if (component.startsWith('maprisma-launcher-') &&
          component.endsWith('.desktop')) {
        continue;
      }
      // Other apps' command shortcuts are ordinary bindings here: their key
      // can be taken and is given back like any desktop shortcut.
      for (final action in await globalAccel.actions(component)) {
        if (action.length < 4) continue;
        found.add((
          '$schemaPrefix$component',
          action[1],
          action[3],
          await getStrv(component, action[1]),
        ));
      }
    }
    return found;
  }

  @override
  Future<List<String>> getStrv(String schema, String key) async => [
    for (final sequence in await globalAccel.shortcutKeys(_id(schema, key)))
      ?_single(sequence),
  ];
  @override
  Future<void> setStrv(String schema, String key, List<String> values) async {
    final converted = <List<int>>[];
    for (final value in values) {
      final code = acceleratorToQt(value);
      if (code == null) throw ArgumentError.value(value, 'accelerator');
      converted.add([code]);
    }
    final old = await globalAccel.shortcutKeys(_id(schema, key));
    await globalAccel.setForeignShortcutKeys(_id(schema, key), [
      for (final seq in old)
        if (_single(seq) == null) seq,
      ...converted,
    ]);
  }

  Map<String, String> _desktop(String component) {
    for (final dir in desktopDirectories(session)) {
      final text = readDesktopFile(p.join(dir, component));
      if (text == null) continue;
      final values = <String, String>{};
      var main = false;
      for (final line in text.split('\n')) {
        if (line.startsWith('[')) {
          main = line.trim() == '[Desktop Entry]';
          continue;
        }
        final i = line.indexOf('=');
        if (main && i > 0) {
          values[line.substring(0, i)] = _unescape(line.substring(i + 1));
        }
      }
      return values;
    }
    return {};
  }

  /// Only ours: the user's own KDE command shortcuts are bindings
  /// ([bindingKeys]), so taking their key gives it back properly.
  @override
  Future<List<String>> customPaths() async {
    final paths = <String>{};
    final dir = Directory(applications);
    if (dir.existsSync()) {
      for (final file in dir.listSync()) {
        final name = p.basename(file.path);
        if (_ours(name)) paths.add(_path(name));
      }
    }
    return paths.toList()..sort();
  }

  @override
  Future<void> setCustomPaths(List<String> paths) async {
    for (final old in await customPaths()) {
      if (!paths.contains(old)) await resetCustom(old);
    }
  }

  @override
  Future<Map<String, String>> readCustom(String path) async {
    final c = _existing(path);
    if (c == null) return {'name': '', 'command': '', 'binding': ''};
    final values = _desktop(c);
    final actions = await globalAccel.actions(c);
    final action = actions
        .where((a) => a.length >= 4 && a[1] == '_launch')
        .firstOrNull;
    final keys = action == null ? <String>[] : await getStrv(c, '_launch');
    return {
      'name': values['Name'] ?? (action == null ? c : action[2]),
      'command': values['X-Maprisma-Command'] ?? '',
      'binding': keys.firstOrNull ?? (action == null ? values['X-Maprisma-Binding'] ?? '' : ''),
    };
  }

  @override
  Future<void> writeCustom(String path, Map<String, String> values) async {
    _slot(path);
    final merged = {...await readCustom(path), ...values};
    final binding = merged['binding']!,
        command = merged['command']!,
        name = merged['name']!;
    final code = binding.isEmpty ? null : acceleratorToQt(binding);
    if (binding.isNotEmpty && code == null) throw ArgumentError.value(binding);
    // Exec arguments use desktop-entry double quoting, then value escaping.
    // Percent signs must also be escaped to prevent desktop field expansion.
    final argument = command
        .replaceAll('%', '%%')
        .replaceAllMapped(RegExp(r'[\\"`$]'), (m) => '\\${m[0]}');
    final text =
        '[Desktop Entry]\nType=Application\nName=${_escape(name)}\nExec=${_escape('sh -c "$argument"')}\nNoDisplay=true\nX-KDE-GlobalAccel-CommandShortcut=true\nX-Maprisma-Binding=${_escape(binding)}\nX-Maprisma-Command=${_escape(command)}\n';
    // A changed command is a new component: the old one goes first.
    final c = '${_slot(path)}-${_hash(command)}.desktop';
    final old = _existing(path);
    if (old != null && old != c) await _remove(old);
    Directory(applications).createSync(recursive: true);
    final temp = File(p.join(applications, '.$c.$pid.tmp'));
    if (temp.existsSync()) temp.deleteSync();
    await temp.writeAsString(text, flush: true);
    await temp.rename(p.join(applications, c));
    // KDE finds the new file through its service cache: refresh it first. Its
    // shortcut service looks at that cache again only after a moment, so
    // several new keys in one go can be dropped without an error (seen live:
    // of three keys made in the same second only the first took). Each key is
    // checked and registered again after a pause until KDE has it.
    final sycoca = session.which('kbuildsycoca6');
    final id = [c, '_launch', 'Maprisma Launcher', name];
    for (var attempt = 0; ; attempt++) {
      if (sycoca != null) {
        await readBoundedText([sycoca], maxBytes: 64 * 1024, timeout: const Duration(seconds: 30), environment: session.environment);
      }
      await globalAccel.doRegister(id);
      await globalAccel.setForeignShortcutKeys(id, [
        if (code != null) [code],
      ]);
      if (code == null) return;
      final taken = await globalAccel.shortcutKeys(_id(c, '_launch'));
      if (taken.any((k) => k.isNotEmpty && k.first == code)) {
        // Active now, not only after the next login (seen live: a pressed key
        // did nothing while KDE listed it).
        await globalAccel.setPresent(id, [
          [code],
        ]);
        return;
      }
      if (attempt >= 3) {
        throw ServiceError('not_applied', 'KDE did not take the key for $name');
      }
      await Future<void>.delayed(retryPause);
    }
  }

  /// The pause before a key KDE dropped is registered again (tests: zero).
  Duration retryPause = const Duration(milliseconds: 1500);

  @override
  Future<void> resetCustom(String path) async {
    final c = _existing(path);
    if (c != null) await _remove(c);
  }

  Future<void> _remove(String c) async {
    await globalAccel.setForeignShortcutKeys(_id(c, '_launch'), []);
    await globalAccel.unregister(c, '_launch');
    final file = File(p.join(applications, c));
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<void> sync() async {}
}

String _escape(String value) => value
    .replaceAll('\\', r'\\')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');
String _unescape(String value) => value.replaceAllMapped(
  RegExp(r'\\([snrt\\])'),
  (m) => switch (m[1]) {
    's' => ' ',
    'n' => '\n',
    'r' => '\r',
    't' => '\t',
    _ => '\\',
  },
);
