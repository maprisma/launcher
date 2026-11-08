import 'dart:io';

import 'package:maprisma_launcher_core/src/desktop_entries.dart';
import 'package:maprisma_launcher_core/src/svg_inline.dart';
import 'package:test/test.dart';

const breeze = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">\n'
    '<defs><style type="text/css" id="current-color-scheme">.ColorScheme-Text { color:#232629; }\n'
    '.ColorScheme-Accent { color:#3daee9; } .ColorScheme-NegativeText { color:#da4453; }</style></defs>\n'
    '<path style="fill:currentColor" class="ColorScheme-Text" d="M1 1"/>\n'
    '<path style="fill:currentColor" class="ColorScheme-Accent" d="M2 2"/>\n'
    '<path fill="currentColor" class="ColorScheme-NegativeText" d="M3 3"/>\n'
    '<rect style="fill:currentColor" width="1" height="1"/>\n</svg>';

void main() {
  test('stylesheet colours go into the shapes; Text and Accent follow the theme', () {
    final out = inlineSvgColors(breeze, {'foreground': '#e8d5b7', 'accent': '#e78a4e'})!;
    expect(out, isNot(contains('<style')));
    expect(out, isNot(contains('currentColor')));
    expect(out, contains('class="ColorScheme-Text" d="M1 1"'));
    expect(out, contains('style="fill:#e8d5b7" class="ColorScheme-Text"'));
    expect(out, contains('style="fill:#e78a4e" class="ColorScheme-Accent"'));
    expect(out, contains('fill="#da4453" class="ColorScheme-NegativeText"')); // its own colour
    expect(out, contains('<rect style="fill:#e8d5b7"')); // no class: the text colour
  });

  test('without a theme the stylesheet colours stay; plain SVGs are left alone', () {
    expect(inlineSvgColors(breeze, const {}), contains('fill:#232629'));
    expect(inlineSvgColors('<svg><path fill="#fff"/></svg>', const {'foreground': '#000000'}), isNull);
  });

  test("Inkscape's svg: element prefix is removed (Flutter skips such elements)", () {
    const inkscape = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg">'
        '<svg:g><svg:rect width="1" height="1" style="fill:#123456"/></svg:g></svg>';
    final out = drawableSvg(inkscape, const {})!;
    expect(out, contains('<g><rect width="1"'));
    expect(out, contains('</g></svg>'));
    expect(out, contains('xmlns:svg=')); // the declaration itself stays
    expect(drawableSvg('<svg><rect/></svg>', const {}), isNull);
  });

  test('a cached copy only when needed', () {
    final dir = Directory.systemTemp.createTempSync('svg-inline-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final session = Session(environment: {'HOME': dir.path, 'XDG_CACHE_HOME': '${dir.path}/cache'});
    final styled = File('${dir.path}/a.svg')..writeAsStringSync(breeze);
    final plain = File('${dir.path}/b.svg')..writeAsStringSync('<svg><path fill="#fff"/></svg>');
    final png = File('${dir.path}/c.png')..writeAsBytesSync([0x89, 0x50]);
    final copy = drawableIcon(styled.path, {'foreground': '#ffffff'}, session);
    expect(copy, startsWith('${dir.path}/cache/maprisma-launcher/inline-icons/'));
    expect(File(copy).readAsStringSync(), contains('fill:#ffffff'));
    expect(drawableIcon(styled.path, {'foreground': '#ffffff'}, session), copy); // cached
    expect(drawableIcon(plain.path, const {}, session), plain.path);
    expect(drawableIcon(png.path, const {}, session), png.path);
  });
}
