import 'package:flutter/material.dart';

import 'theme.dart' show Corners;

const String skinKey = 'skin';

const List<String> appSkins = [
  'native',
  'synthwave',
  'cozy',
  'terminal',
  'disco',
  'zen',
];

String _hex(Color c) => '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// Visual accent palette for a non-native app skin.
@immutable
class AppSkinStyle {
  const AppSkinStyle({
    required this.accent,
    required this.borderTint,
    required this.bgTint,
    required this.windowBg,
    required this.foreground,
    required this.borderWidth,
  });

  final Color accent;
  final Color borderTint;
  final Color bgTint;
  final Color windowBg;
  final Color foreground;
  final double borderWidth;

  Map<String, String> toDesktopColors() => {
    'accent': _hex(accent),
    'background': _hex(windowBg),
    'foreground': _hex(foreground),
  };
}

/// Active non-native skin attached to [ThemeData] for custom cards/surfaces.
class AppSkinTheme extends ThemeExtension<AppSkinTheme> {
  const AppSkinTheme({required this.skin, required this.style});

  final String skin;
  final AppSkinStyle style;

  @override
  AppSkinTheme copyWith({String? skin, AppSkinStyle? style}) =>
      AppSkinTheme(skin: skin ?? this.skin, style: style ?? this.style);

  @override
  AppSkinTheme lerp(AppSkinTheme? other, double t) => other ?? this;
}

const _synthwaveSkin = AppSkinStyle(
  accent: Color(0xffff2e93),
  borderTint: Color(0xff00e5ff),
  bgTint: Color(0xff3a1259),
  windowBg: Color(0xff130924),
  foreground: Color(0xfff4eaff),
  borderWidth: 1.5,
);

const _cozySkin = AppSkinStyle(
  accent: Color(0xfff09a36),
  borderTint: Color(0xffe0822a),
  bgTint: Color(0xff593012),
  windowBg: Color(0xff21150e),
  foreground: Color(0xfff5e8d6),
  borderWidth: 1.25,
);

const _terminalSkin = AppSkinStyle(
  accent: Color(0xff2ce868),
  borderTint: Color(0xff22c55e),
  bgTint: Color(0xff0d381a),
  windowBg: Color(0xff09130b),
  foreground: Color(0xffd2fce0),
  borderWidth: 1.25,
);

const _discoSkin = AppSkinStyle(
  accent: Color(0xffd946ef),
  borderTint: Color(0xfffacc15),
  bgTint: Color(0xff4c1666),
  windowBg: Color(0xff1c0c2b),
  foreground: Color(0xfff8ecff),
  borderWidth: 1.5,
);

const _zenSkin = AppSkinStyle(
  accent: Color(0xff52b798),
  borderTint: Color(0xff64c2a4),
  bgTint: Color(0xff1e3832),
  windowBg: Color(0xff141d1c),
  foreground: Color(0xffe2f0ec),
  borderWidth: 1.0,
);

/// Normalizes missing or unknown skin ids to `'native'`.
String normalizeSkin(String? raw) => appSkins.contains(raw) ? raw! : 'native';

/// Visual palette for a non-native skin, or null for `'native'`.
AppSkinStyle? skinStyle(String? skin) => switch (normalizeSkin(skin)) {
  'synthwave' => _synthwaveSkin,
  'cozy' => _cozySkin,
  'terminal' => _terminalSkin,
  'disco' => _discoSkin,
  'zen' => _zenSkin,
  _ => null,
};

/// Localized display label for a skin id.
String skinLabel(String? skin, String Function(String) tr) => switch (normalizeSkin(skin)) {
  'synthwave' => tr('Synthwave'),
  'cozy' => tr('Cozy'),
  'terminal' => tr('Terminal'),
  'disco' => tr('Disco'),
  'zen' => tr('Zen'),
  _ => tr('Native'),
};

/// Applies a non-native app skin to [base]; returns [base] unchanged for `'native'`.
///
/// Leaves window/card colors opaque so [withWindowAlpha] composes cleanly on top.
ThemeData applySkinToTheme(ThemeData base, String? skin, {double? radius}) {
  final st = skinStyle(skin);
  if (st == null) return base;
  final normalized = normalizeSkin(skin);
  final effectiveRadius = radius ?? base.extension<Corners>()?.radius ?? 12.0;
  final sizes = Corners(effectiveRadius);
  final control = BorderRadius.circular(sizes.control);
  final controlShape = RoundedRectangleBorder(borderRadius: control);
  final cardBg = Color.alphaBlend(st.bgTint.withValues(alpha: 0.28), st.windowBg);
  final borderColor = st.borderTint.withValues(alpha: 0.48);
  final outlineVariant = st.borderTint.withValues(alpha: 0.42);
  final onPrimary = st.accent.computeLuminance() > 0.4 ? Colors.black : Colors.white;
  final seeded = ColorScheme.fromSeed(seedColor: st.accent, brightness: Brightness.dark);
  final scheme = seeded.copyWith(
    primary: st.accent,
    onPrimary: onPrimary,
    surface: st.windowBg,
    onSurface: st.foreground,
    onSurfaceVariant: Color.lerp(st.windowBg, st.foreground, 0.62)!,
    surfaceContainerLowest: Color.lerp(st.windowBg, st.bgTint, 0.14)!,
    surfaceContainerLow: cardBg,
    surfaceContainer: Color.alphaBlend(st.bgTint.withValues(alpha: 0.36), st.windowBg),
    surfaceContainerHigh: Color.alphaBlend(st.bgTint.withValues(alpha: 0.46), st.windowBg),
    surfaceContainerHighest: Color.alphaBlend(st.bgTint.withValues(alpha: 0.56), st.windowBg),
    outlineVariant: outlineVariant,
    secondaryContainer: Color.alphaBlend(st.accent.withValues(alpha: 0.24), st.windowBg),
    onSecondaryContainer: st.foreground,
  );
  final darkText = base.brightness == Brightness.dark
      ? base.textTheme.apply(bodyColor: st.foreground, displayColor: st.foreground)
      : ThemeData(
          colorScheme: scheme,
          useMaterial3: true,
          fontFamily: base.textTheme.bodyMedium?.fontFamily,
        ).textTheme;
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(effectiveRadius),
    side: BorderSide(color: borderColor, width: st.borderWidth),
  );
  final extensions = base.extensions.values.where((e) => e is! AppSkinTheme).toList()
    ..add(AppSkinTheme(skin: normalized, style: st));
  return base.copyWith(
    colorScheme: scheme,
    textTheme: darkText,
    scaffoldBackgroundColor: st.windowBg,
    canvasColor: st.windowBg,
    extensions: extensions,
    cardTheme: base.cardTheme.copyWith(
      color: cardBg,
      elevation: 0,
      shape: cardShape,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Color.alphaBlend(st.bgTint.withValues(alpha: 0.22), st.windowBg),
      selectedColor: Color.alphaBlend(st.accent.withValues(alpha: 0.24), st.windowBg),
      side: BorderSide(color: borderColor, width: 1.0),
      labelStyle: TextStyle(color: st.foreground),
      secondaryLabelStyle: TextStyle(color: st.foreground),
      shape: controlShape,
    ),
    dividerTheme: base.dividerTheme.copyWith(
      color: st.borderTint.withValues(alpha: 0.28),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(effectiveRadius),
        side: BorderSide(color: borderColor, width: 1.0),
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(effectiveRadius),
        side: BorderSide(color: borderColor, width: st.borderWidth),
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: scheme.surfaceContainer,
      focusedBorder: OutlineInputBorder(
        borderRadius: control,
        borderSide: BorderSide(color: st.accent, width: 1.5),
      ),
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: control,
        border: Border.all(color: outlineVariant),
      ),
      textStyle: (base.tooltipTheme.textStyle ?? const TextStyle(fontSize: 13)).copyWith(color: st.foreground),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: st.foreground),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: st.accent,
      inactiveTrackColor: st.foreground.withValues(alpha: 0.15),
      thumbColor: st.accent,
    ),
  );
}
