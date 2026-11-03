import 'dart:io';

import 'package:appmanager_core/appmanager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Exec lines', () {
    test('field codes and quoting', () {
      expect(execArgv('foo %U --x'), ['foo', '--x']);
      expect(execArgv('foo %i', icon: 'my icon'), ['foo', '--icon', 'my icon']);
      expect(execArgv('foo %i'), ['foo']);
      expect(execArgv('foo %c', name: "It's"), ['foo', "It's"]);
      expect(execArgv('foo %k', desktopFile: '/a b/x.desktop'), ['foo', '/a b/x.desktop']);
      expect(execArgv('foo 100%%'), ['foo', '100%']);
      expect(execArgv(r'sh -c "echo \"\$HOME\" \\ \x"'), ['sh', '-c', r'echo "$HOME" \ \x']);
      expect(execArgv("a 'b c' d\\ e"), ['a', 'b c', 'd e']);
      expect(execArgv('foo "unclosed'), isNull);
      expect(execArgv('%U'), isNull);
    });

    test('desktop file command: actions, Path, Terminal', () {
      final dir = Directory.systemTemp.createTempSync('am-launch-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = p.join(dir.path, 'x.desktop');
      File(file).writeAsStringSync(
        '[Desktop Entry]\nType=Application\nName=X\nIcon=xi\n'
        'Exec=prog --name %c %f\nPath=${dir.path}\nTerminal=true\nActions=new;\n'
        '[Desktop Action new]\nName=New\nExec=prog --new %k\n'
        '[Desktop Action hidden]\nExec=prog --hidden\n',
      );
      final session = Session(environment: {'HOME': dir.path});
      final main = desktopCommand(file, session)!;
      expect(main.argv, ['prog', '--name', 'X']);
      expect(main.terminal, isTrue);
      expect(main.cwd, dir.path);
      expect(desktopCommand(file, session, action: 'new')!.argv, ['prog', '--new', file]);
      // Not listed under Actions: Gio would not run it either.
      expect(desktopCommand(file, session, action: 'hidden'), isNull);
    });
  });

  group('Omarchy', () {
    test('colors.toml: own keys, old keys, muted, defaults', () {
      final c = OmarchyDesktop.colorsFromToml(
        'accent = "#ABC"\nbackground = "#101010"\ncolor1 = "#ff0000"\n'
        'selection_background = "#222222"\ndark_foreground = "#555555"\n'
        'foreground = "nope"\n',
      );
      expect(c['accent'], '#aabbcc');
      expect(c['background'], '#101010');
      expect(c['red'], '#ff0000');
      expect(c['selection'], '#222222');
      expect(c['muted'], '#555555');
      expect(c['foreground'], defaultColors['foreground']);
      expect(OmarchyDesktop.colorsFromToml('not = toml = x'), defaultColors);
      expect(OmarchyDesktop.colorsFromToml(null), defaultColors);
    });

    test('rounding from hyprctl', () {
      expect(OmarchyDesktop.parseRounding('{"int": 8}'), 8);
      expect(OmarchyDesktop.parseRounding('{"int": 99}'), 24);
      expect(OmarchyDesktop.parseRounding('{"int": true}'), isNull);
      expect(OmarchyDesktop.parseRounding('garbage'), isNull);
    });
  });

  group('COSMIC', () {
    const background = '''(
    base: (red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0),
    component: (
        base: (red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        on: (red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
    ),
    on: (red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0),
)''';
    test('RON fields at the top level only', () {
      expect(ronColor(ronField(background, 'base')), '#1a334d');
      expect(ronColor(ronField(background, 'on')), '#e6e6e6');
      expect(ronField(background, 'missing'), isNull);
    });

    test('theme files', () async {
      final home = Directory.systemTemp.createTempSync('am-cosmic-');
      addTearDown(() => home.deleteSync(recursive: true));
      void put(String component, String key, String text) =>
          File(p.join(home.path, '.config/cosmic', component, 'v1', key))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      put('com.system76.CosmicTheme.Mode', 'is_dark', 'false');
      put('com.system76.CosmicTheme.Light', 'background', background);
      put('com.system76.CosmicTheme.Light', 'accent',
          '(base: (red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0), on: (red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))');
      put('com.system76.CosmicTheme.Light', 'corner_radii',
          '(radius_0: (0.0, 0.0, 0.0, 0.0), radius_s: (8.0, 8.0, 8.0, 8.0))');
      put('com.system76.CosmicTk', 'icon_theme', '"Pop"');
      final desktop = CosmicDesktop(Session(environment: {'HOME': home.path}));
      final colors = await desktop.themeColors();
      expect(colors['background'], '#1a334d');
      expect(colors['foreground'], '#e6e6e6');
      expect(colors['accent'], '#0080ff');
      expect(colors['green'], GnomeDesktop.light['green']);
      expect(await desktop.windowRounding(), 8);
      expect(await desktop.iconTheme(), 'Pop');
    });
  });

  test('desktop detection', () {
    Desktop d(Map<String, String> env) => detectDesktop(Session(environment: {'HOME': '/', ...env}));
    expect(d({'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME'}).name, 'gnome');
    expect(d({'XDG_CURRENT_DESKTOP': 'COSMIC'}).name, 'cosmic');
    expect(d({'XDG_CURRENT_DESKTOP': 'KDE'}).name, 'generic');
    expect(d({'XDG_CURRENT_DESKTOP': 'KDE', 'APPMANAGER_DESKTOP': 'gnome'}).name, 'gnome');
    expect(
      d({'HYPRLAND_INSTANCE_SIGNATURE': 'x', 'OMARCHY_PATH': '/nonexistent'}).name,
      'generic',
    );
  });
}
