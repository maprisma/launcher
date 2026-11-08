import 'dart:io';

import 'package:maprisma_launcher_core/src/cosmic_windows.dart';
import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/desktops.dart';
import 'package:maprisma_launcher_core/src/kde_windows.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('launcher-kde-'));
  tearDown(() => home.deleteSync(recursive: true));

  test('a Plasma session is KDE; the override wins', () {
    Desktop d(Map<String, String> env) => detectDesktop(Session(environment: {'HOME': home.path, ...env}));
    expect(d({'XDG_CURRENT_DESKTOP': 'KDE'}), isA<KdeDesktop>());
    expect(d({'XDG_CURRENT_DESKTOP': 'KDE', 'MAPRISMA_LAUNCHER_DESKTOP': 'cosmic'}), isA<CosmicDesktop>());
    expect(d({'MAPRISMA_LAUNCHER_DESKTOP': 'kde'}), isA<KdeDesktop>());
  });

  test("Plasma's colours, accent and icon theme from kdeglobals", () async {
    Directory('${home.path}/.config').createSync();
    File('${home.path}/.config/kdeglobals').writeAsStringSync('[Colors:Selection]\nBackgroundNormal=60,50,40\n\n'
        '[Colors:View]\nDecorationFocus=214,104,46\nForegroundNegative=200,40,40\nForegroundPositive=40,160,60\n\n'
        '[Colors:Window]\nBackgroundNormal=40,30,24\nForegroundNormal=230,220,210\nForegroundInactive=150,140,130\n\n'
        '[Icons]\nTheme=Papirus-Dark\n');
    final kde = KdeDesktop(Session(environment: {'HOME': home.path}));
    final c = await kde.themeColors();
    expect(c['background'], '#281e18');
    expect(c['foreground'], '#e6dcd2');
    expect(c['accent'], '#d6682e'); // the focus decoration, not the muted selection
    expect(c['red'], '#c82828');
    expect(c['muted'], '#968c82');
    expect(await kde.iconTheme(), 'Papirus-Dark');
    expect((await kde.look())['desktop'], 'kde');
  });

  test('defaults without kdeglobals', () async {
    final kde = KdeDesktop(Session(environment: {'HOME': home.path}));
    expect((await kde.themeColors())['accent'], '#3daee9');
    expect(await kde.iconTheme(), 'breeze');
    expect(await kde.windowRounding(), 8);
  });

  test('without a session bus KWin is never reached: no windows, nothing done', () async {
    final w = KdeWindows(Session(environment: {'HOME': home.path}));
    expect(await w.clients(), isNull);
    expect(await w.focus('{00000000-0000-0000-0000-000000000000}'), isFalse);
    expect(await w.closeWindow('{00000000-0000-0000-0000-000000000000}'), isFalse);
  });

  test('KWin windows match entries by desktop file name, as COSMIC ones', () {
    final windows = [
      {'id': '{a}', 'app_id': 'org.kde.konsole', 'title': 'Shell', 'workspace': 2, 'active': false},
      {'id': '{b}', 'app_id': 'org.kde.konsole', 'title': 'Logs', 'workspace': 1, 'active': true},
    ];
    final app = {'desktop_id': 'org.kde.konsole.desktop', 'exec': 'konsole'};
    expect([for (final w in toplevelWindowsOf(app, windows)) w['address']], ['{b}', '{a}']);
  });
}
