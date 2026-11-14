// desktop.look's fonts {ui, mono}: COSMIC's CosmicTk, KDE's kdeglobals, elsewhere GTK's
// gsettings (a fake on PATH, never the real one).
import 'dart:io';

import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/desktops.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late String bin;
  setUp(() {
    home = Directory.systemTemp.createTempSync('launcher-fonts-');
    bin = (Directory('${home.path}/bin')..createSync()).path;
  });
  tearDown(() => home.deleteSync(recursive: true));

  void put(String path, String text) => File(p.join(home.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  Session session(String current) =>
      Session(environment: {'HOME': home.path, 'PATH': bin, 'XDG_CURRENT_DESKTOP': current});

  test('COSMIC: CosmicTk\'s interface_font / monospace_font family, v2 before v1', () async {
    final cosmic = CosmicDesktop(session('COSMIC'), systemDir: p.join(home.path, 'no-system'));
    expect((await cosmic.look())['fonts'], isEmpty);
    put('.config/cosmic/com.system76.CosmicTk/v1/interface_font', '(\n    family: "Old Sans",\n    weight: Normal,\n)');
    put('.config/cosmic/com.system76.CosmicTk/v2/interface_font', '(\n    family: "Open Sans",\n    weight: Normal,\n)');
    put('.config/cosmic/com.system76.CosmicTk/v1/monospace_font', '(\n    family: "Hack",\n    weight: Normal,\n)');
    expect((await cosmic.look())['fonts'], {'ui': 'Open Sans', 'mono': 'Hack'});
  });

  test('KDE: kdeglobals [General] font / fixed, the family only', () async {
    final kde = KdeDesktop(session('KDE'));
    expect((await kde.look())['fonts'], isEmpty);
    put('.config/kdeglobals', '[General]\nfixed=Hack,10,-1,5,400,0,0,0,0,0\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0\n');
    expect((await kde.look())['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
  });

  test('Hyprland: GTK\'s gsettings without the size, asked at most every 30 s', () async {
    File('$bin/gsettings')
      ..writeAsStringSync('#!/bin/sh\necho "\$@" >> "$bin/gs.log"\n'
          'case "\$3" in font-name) echo "\'Noto Sans  10\'";; monospace-font-name) echo "\'Hack, 10.5\'";; esac\n');
    Process.runSync('/usr/bin/chmod', ['755', '$bin/gsettings']);
    var now = DateTime(2026, 1, 1);
    final hypr = GenericDesktop(session('Hyprland'))..clock = () => now;
    expect((await hypr.look())['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
    int asked() => File('$bin/gs.log').readAsLinesSync().where((l) => l.contains('font-name')).length;
    now = now.add(const Duration(seconds: 10));
    await hypr.look();
    expect(asked(), 2);
    now = now.add(const Duration(seconds: 25));
    await hypr.look();
    expect(asked(), 4);
    expect(pangoFamily('JetBrains Mono Nerd Font 12'), 'JetBrains Mono Nerd Font');
    expect(pangoFamily('Hack'), 'Hack');
    expect(cleanFont('  '), isNull);
  });

  test('without gsettings: no fonts', () async {
    expect((await GenericDesktop(session('Hyprland')).look())['fonts'], isEmpty);
  });
}
