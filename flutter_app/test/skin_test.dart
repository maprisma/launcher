import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/settings_page.dart';
import 'package:maprisma_launcher/skin.dart';
import 'package:maprisma_launcher/theme.dart';
import 'package:maprisma_launcher/window_style.dart';

void main() {
  test('appSkins order and normalizeSkin', () {
    expect(appSkins, ['native', 'synthwave', 'cozy', 'terminal', 'disco', 'zen']);
    for (final s in appSkins) {
      expect(normalizeSkin(s), s);
    }
    expect(normalizeSkin(null), 'native');
    expect(normalizeSkin(''), 'native');
    expect(normalizeSkin('unknown'), 'native');
  });

  test('skinStyle returns exact palettes and null for native', () {
    expect(skinStyle('native'), isNull);
    expect(skinStyle(null), isNull);
    expect(skinStyle('bogus'), isNull);

    final synth = skinStyle('synthwave')!;
    expect(synth.accent, const Color(0xffff2e93));
    expect(synth.borderTint, const Color(0xff00e5ff));
    expect(synth.bgTint, const Color(0xff3a1259));
    expect(synth.windowBg, const Color(0xff130924));
    expect(synth.foreground, const Color(0xfff4eaff));
    expect(synth.borderWidth, 1.5);
    expect(synth.toDesktopColors(), {
      'accent': '#ff2e93',
      'background': '#130924',
      'foreground': '#f4eaff',
    });

    final cozy = skinStyle('cozy')!;
    expect(cozy.accent, const Color(0xfff09a36));
    expect(cozy.borderTint, const Color(0xffe0822a));
    expect(cozy.bgTint, const Color(0xff593012));
    expect(cozy.windowBg, const Color(0xff21150e));
    expect(cozy.foreground, const Color(0xfff5e8d6));
    expect(cozy.borderWidth, 1.25);

    final term = skinStyle('terminal')!;
    expect(term.accent, const Color(0xff2ce868));
    expect(term.borderTint, const Color(0xff22c55e));
    expect(term.bgTint, const Color(0xff0d381a));
    expect(term.windowBg, const Color(0xff09130b));
    expect(term.foreground, const Color(0xffd2fce0));
    expect(term.borderWidth, 1.25);

    final disco = skinStyle('disco')!;
    expect(disco.accent, const Color(0xffd946ef));
    expect(disco.borderTint, const Color(0xfffacc15));
    expect(disco.bgTint, const Color(0xff4c1666));
    expect(disco.windowBg, const Color(0xff1c0c2b));
    expect(disco.foreground, const Color(0xfff8ecff));
    expect(disco.borderWidth, 1.5);

    final zen = skinStyle('zen')!;
    expect(zen.accent, const Color(0xff52b798));
    expect(zen.borderTint, const Color(0xff64c2a4));
    expect(zen.bgTint, const Color(0xff1e3832));
    expect(zen.windowBg, const Color(0xff141d1c));
    expect(zen.foreground, const Color(0xffe2f0ec));
    expect(zen.borderWidth, 1.0);
  });

  test('applySkinToTheme keeps native untouched and skins cards, surfaces, and borders', () {
    final lightBase = appTheme(Brightness.light, {'background': '#ffffff', 'foreground': '#111111'}, 10);
    expect(identical(applySkinToTheme(lightBase, 'native'), lightBase), isTrue);

    final skinned = appTheme(Brightness.light, {'background': '#ffffff', 'foreground': '#111111'}, 10, skin: 'synthwave');
    final st = skinStyle('synthwave')!;
    expect(skinned.brightness, Brightness.dark);
    expect(skinned.scaffoldBackgroundColor, st.windowBg);
    expect(skinned.colorScheme.primary, st.accent);
    expect(skinned.colorScheme.onSurface, st.foreground);
    expect(skinned.colorScheme.outlineVariant, st.borderTint.withValues(alpha: 0.42));
    expect(skinned.cardTheme.color, Color.alphaBlend(st.bgTint.withValues(alpha: 0.28), st.windowBg));
    final shape = skinned.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, st.borderTint.withValues(alpha: 0.48));
    expect(shape.side.width, st.borderWidth);
    expect(skinned.extension<AppSkinTheme>()?.skin, 'synthwave');
  });

  test('skinned theme composes cleanly with withWindowAlpha', () {
    final base = appTheme(Brightness.dark, const {}, 12, skin: 'disco');
    final glassy = withWindowAlpha(base, glassyAlpha);
    expect(glassy.scaffoldBackgroundColor.a, closeTo(glassyAlpha, 1e-6));
    expect(glassy.cardTheme.color!.a, closeTo((1 + glassyAlpha) / 2, 1e-6));
    expect(glassy.colorScheme.surfaceContainerLow.a, closeTo((1 + glassyAlpha) / 2, 1e-6));
    expect(glassy.popupMenuTheme.color!.a, closeTo(1.0, 1e-6));
    expect(glassy.dialogTheme.backgroundColor!.a, closeTo(1.0, 1e-6));
  });

  testWidgets('SettingsPage offers App skin next to Corners and saves chosen skin', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final saved = <(String, Object?)>[];
    var current = <String, dynamic>{'corners': 'windows', 'skin': 'native'};

    Future<Map<String, dynamic>> fakeCore(String method, [Map<String, dynamic>? params]) async {
      if (method == 'settings.set') {
        final key = params!['key'] as String;
        final value = params['value'];
        saved.add((key, value));
        current = {...current, key: value};
        return current;
      }
      if (method == 'packages.managers') return {'managers': []};
      if (method == 'admin.state') return {'available': false};
      if (method == 'dock.state') return {'available': false};
      if (method == 'ask.helpers') return {'helpers': []};
      return {};
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 12),
        home: SettingsPage(
          core: fakeCore,
          settings: current,
          onChanged: (next) => current = next,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-section-layout')));
    await tester.pumpAndSettle();

    expect(find.text('App skin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-skin')));
    await tester.pumpAndSettle();

    expect(find.text('Synthwave'), findsOneWidget);
    expect(find.text('Cozy'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Disco'), findsOneWidget);
    expect(find.text('Zen'), findsOneWidget);

    await tester.tap(find.text('Synthwave').last);
    await tester.pumpAndSettle();

    expect(saved, [('skin', 'synthwave')]);
    expect(current['skin'], 'synthwave');
  });
}
