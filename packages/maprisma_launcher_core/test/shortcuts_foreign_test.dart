/// One shortcuts.json is shared by every desktop of a home: a binding taken on
/// COSMIC is never handed to KDE's kglobalaccel (or the reverse), and its
/// record survives a save on the other desktop.
library;

import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:test/test.dart';

final class _Recording implements KeySettings {
  final calls = <String>[];
  final binds = <String, List<String>>{'kde/kwin:Overview': ['<Super>w']};
  @override
  Future<bool> available() async => true;
  @override
  Future<List<(String, String, String, List<String>)>> bindingKeys() async => [];
  @override
  Future<List<String>> getStrv(String schema, String key) async {
    calls.add('get $schema:$key');
    return [...?binds['$schema:$key']];
  }

  @override
  Future<void> setStrv(String schema, String key, List<String> values) async {
    calls.add('set $schema:$key');
    binds['$schema:$key'] = values;
  }

  @override
  Future<List<String>> customPaths() async => [];
  @override
  Future<void> setCustomPaths(List<String> paths) async {}
  @override
  Future<Map<String, String>> readCustom(String path) async => {};
  @override
  Future<void> writeCustom(String path, Map<String, String> values) async {}
  @override
  Future<void> resetCustom(String path) async {}
  @override
  Future<void> sync() async {}
}

void main() {
  test('whereBelongsTo: each desktop owns only its own schema', () {
    expect(whereBelongsTo('kde', 'kde/kwin:Overview'), isTrue);
    expect(whereBelongsTo('kde', 'cosmic.shortcuts:launcher'), isFalse);
    expect(whereBelongsTo('cosmic', 'cosmic.shortcuts:launcher'), isTrue);
    expect(whereBelongsTo('cosmic', 'kde/kwin:Overview'), isFalse);
    expect(whereBelongsTo('gnome', 'org.gnome.shell.keybindings:toggle-overview'), isTrue);
    expect(whereBelongsTo('gnome', 'kde/kwin:Overview'), isFalse);
    expect(whereBelongsTo('kde', 'custom:/org/x/'), isTrue);
  });

  test('a save on KDE leaves COSMIC records alone and keeps them', () async {
    final settings = _Recording();
    final state = {
      'apps': {
        'a': {
          'name': 'A',
          'launch': ['a'],
          'shortcuts': [
            {'mods': ['SUPER'], 'key': 'T', 'taken_from': 'cosmic.shortcuts:terminal'},
          ],
          'disabled': [],
        },
      },
    };
    final saved = await applyGnome(
      state,
      settings,
      previousApplied: [
        {'where': 'cosmic.shortcuts:launcher', 'accel': '<Super>a'}, // removed shortcut, COSMIC's
        {'where': 'kde/kwin:Overview', 'accel': '<Super>w'}, // removed shortcut, KDE's
      ],
      ownPrefix: 'maprisma-launcher-',
      command: (launch, action) => launch.join(' '),
      owns: (where) => whereBelongsTo('kde', where),
    );
    expect(settings.calls.where((c) => c.contains('cosmic.shortcuts')), isEmpty);
    // KDE's own one is given back (already there, so nothing set)
    expect(settings.calls, contains('get kde/kwin:Overview'));
    expect(saved['applied'], [
      {'where': 'cosmic.shortcuts:launcher', 'accel': '<Super>a'},
    ]);
  });
}
