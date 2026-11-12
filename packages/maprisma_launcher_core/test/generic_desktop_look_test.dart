import 'dart:io';

import 'package:maprisma_launcher_core/src/desktops.dart';
import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('launcher-generic-look-'));
  tearDown(() => home.deleteSync(recursive: true));

  GenericDesktop desktop(String current) =>
      GenericDesktop(Session(environment: {'HOME': home.path, 'XDG_CURRENT_DESKTOP': current}));

  test('Hyprland: Caelestia\'s scheme gives the colours; other desktops and no file give none', () async {
    expect(await desktop('Hyprland').themeColors(), isEmpty);
    File('${home.path}/.local/state/maprisma-shell/scheme.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"colours": {"primary": "89B4FA", "surface": "1e1e2e", "onSurface": "cdd6f4", "green": "x"}}');
    expect(await desktop('Hyprland').themeColors(), {'accent': '#89b4fa', 'background': '#1e1e2e', 'foreground': '#cdd6f4'});
    expect(await desktop('GNOME').themeColors(), isEmpty);
    File('${home.path}/.local/state/maprisma-shell/scheme.json').writeAsStringSync('{broken');
    expect(await desktop('Hyprland').themeColors(), isEmpty);
  });

  group('Hyprland rounding (fake hyprctl)', () {
    late String bin;
    setUp(() => bin = (Directory('${home.path}/bin')..createSync()).path);

    // printf and [ are shell builtins: PATH holds nothing but the fake.
    void hyprctl(String answer) {
      File('$bin/hyprctl')
        ..writeAsStringSync("#!/bin/sh\n[ \"\$*\" = '-j getoption decoration:rounding' ] || exit 3\nprintf '%s\\n' '$answer'\n")
        ..createSync();
      Process.runSync('/usr/bin/chmod', ['755', '$bin/hyprctl']);
    }

    GenericDesktop hypr({String signature = 'test'}) => GenericDesktop(Session(environment: {
          'HOME': home.path,
          'PATH': bin,
          'XDG_CURRENT_DESKTOP': 'Hyprland',
          'HYPRLAND_INSTANCE_SIGNATURE': signature,
        }));

    test('the int of decoration:rounding, clamped to 0–64', () async {
      hyprctl('{"option": "decoration:rounding", "int": 15, "set": true }');
      expect(await hypr().windowRounding(), 15);
      hyprctl('{"option": "decoration:rounding", "int": 200, "set": true }');
      expect(await hypr().windowRounding(), 64);
      hyprctl('{"option": "decoration:rounding", "int": -3, "set": true }');
      expect(await hypr().windowRounding(), 0);
      hyprctl('not json');
      expect(await hypr().windowRounding(), isNull);
      hyprctl('{"int": "15"}');
      expect(await hypr().windowRounding(), isNull);
    });

    test('no hyprctl or no Hyprland session: unknown', () async {
      expect(await hypr().windowRounding(), isNull);
      hyprctl('{"int": 15}');
      expect(await hypr(signature: '').windowRounding(), isNull);
      expect(await desktop('GNOME').windowRounding(), isNull);
    });

    test('asked at most every 30 s', () async {
      hyprctl('{"int": 15}');
      var now = DateTime(2026, 1, 1);
      final d = hypr()..clock = () => now;
      expect(await d.windowRounding(), 15);
      hyprctl('{"int": 4}');
      now = now.add(const Duration(seconds: 10));
      expect(await d.windowRounding(), 15);
      now = now.add(const Duration(seconds: 25));
      expect(await d.windowRounding(), 4);
    });

    test('look carries the rounding', () async {
      hyprctl('{"int": 15}');
      expect((await hypr().look())['rounding'], 15);
    });
  });
}
