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
    File('${home.path}/.local/state/caelestia/scheme.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"colours": {"primary": "89B4FA", "surface": "1e1e2e", "onSurface": "cdd6f4", "green": "x"}}');
    expect(await desktop('Hyprland').themeColors(), {'accent': '#89b4fa', 'background': '#1e1e2e', 'foreground': '#cdd6f4'});
    expect(await desktop('GNOME').themeColors(), isEmpty);
    File('${home.path}/.local/state/caelestia/scheme.json').writeAsStringSync('{broken');
    expect(await desktop('Hyprland').themeColors(), isEmpty);
  });
}
