import 'dart:math';

import 'package:flutter/material.dart';

Color? hexColor(Map colors, String key) {
  final value = colors[key];
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

/// The corner radius in effect (Settings › Corners; the desktop's windows), in three sizes (as
/// Maprisma Playground): the window, cards, folders, dialogs and pop-ups take [radius]; buttons,
/// choice boxes, fields, menus' entries, tooltips and chips [control] (at most 8); check boxes,
/// slider tracks, progress bars and small tags [small] (at most 4); count badges [pill]. Square squares everything; the
/// slider knob stays small (see [KnobShape]).
class Corners extends ThemeExtension<Corners> {
  const Corners(this.radius);
  final double radius;
  double get control => min(radius, 8);
  double get small => min(radius, 4);

  /// Pill badges and toggles: fully round, square with Square corners.
  double get pill => radius <= 0 ? 0 : 999;
  @override
  Corners copyWith({double? radius}) => Corners(radius ?? this.radius);
  @override
  Corners lerp(Corners? other, double t) => other ?? this;
}

/// The marks' colours: running (green), update (orange), new (yellow),
/// from the desktop's palette.
class MarkColors extends ThemeExtension<MarkColors> {
  const MarkColors({required this.running, required this.update, required this.fresh});
  final Color running, update, fresh;
  @override
  MarkColors copyWith({Color? running, Color? update, Color? fresh}) =>
      MarkColors(running: running ?? this.running, update: update ?? this.update, fresh: fresh ?? this.fresh);
  @override
  MarkColors lerp(MarkColors? other, double t) => other ?? this;
}

MarkColors markColors(BuildContext context) => Theme.of(context).extension<MarkColors>() ?? _defaultMarks;

const _defaultMarks = MarkColors(running: Color(0xff3a944a), update: Color(0xffed5b00), fresh: Color(0xffc88800));

/// The palette's green, orange and yellow as marks. They tell states apart
/// (free / desktop default / yours), so a palette where two of them look
/// alike (e.g. a KDE scheme whose "positive" is the orange accent) falls back
/// to the default trio as a whole.
MarkColors markColorsFrom(Map colors) {
  final marks = MarkColors(
    running: hexColor(colors, 'green') ?? _defaultMarks.running,
    update: hexColor(colors, 'orange') ?? _defaultMarks.update,
    fresh: hexColor(colors, 'yellow') ?? _defaultMarks.fresh,
  );
  bool alike(Color a, Color b) {
    final ha = HSLColor.fromColor(a), hb = HSLColor.fromColor(b);
    final hue = (ha.hue - hb.hue).abs();
    return (hue > 180 ? 360 - hue : hue) < 18 && (ha.lightness - hb.lightness).abs() < .25;
  }
  final distinct = !alike(marks.running, marks.update) &&
      !alike(marks.running, marks.fresh) &&
      !alike(marks.update, marks.fresh);
  return distinct ? marks : _defaultMarks;
}

double corners(BuildContext context) => Theme.of(context).extension<Corners>()?.radius ?? 12;

/// Settings › Corners in its three sizes (see [Corners]).
Corners cornerSizes(BuildContext context) => Theme.of(context).extension<Corners>() ?? const Corners(12);

/// "windows" follows the desktop's window corners, "slight" 6 (round controls beside square or
/// tiled windows), "rounded" 12, "square" 0. Older settings files only know the last three and
/// "windows"; they keep working unchanged.
const slightRadius = 6, roundedRadius = 12;
double cornerRadius(String setting, int? windowRounding) => switch (setting) {
  'slight' => 6,
  'rounded' => 12,
  'square' => 0,
  _ => (windowRounding ?? 12).toDouble(),
};

/// The desktop's palette (desktop.look colors) as a Material theme; an
/// empty palette (generic desktops) follows the platform's light or dark.
ThemeData appTheme(Brightness platform, Map colors, double radius) {
  final background = hexColor(colors, 'background');
  final brightness = background == null
      ? platform
      : (background.computeLuminance() < .5 ? Brightness.dark : Brightness.light);
  var scheme = ColorScheme.fromSeed(
    seedColor: hexColor(colors, 'accent') ?? const Color(0xff3584e4),
    brightness: brightness,
  );
  if (background != null) {
    final foreground = hexColor(colors, 'foreground') ?? scheme.onSurface;
    Color step(double amount) => Color.lerp(background, foreground, amount)!;
    final accent = hexColor(colors, 'accent');
    scheme = scheme.copyWith(
      primary: accent ?? scheme.primary,
      // Text on the accent: black on a light accent, else white.
      onPrimary: accent == null ? null : (accent.computeLuminance() > .4 ? Colors.black : Colors.white),
      surface: background,
      onSurface: foreground,
      onSurfaceVariant: hexColor(colors, 'muted') == null
          ? step(.6)
          : Color.lerp(hexColor(colors, 'muted'), foreground, .35),
      surfaceContainerLowest: step(.02),
      surfaceContainerLow: step(.05),
      surfaceContainer: step(.08),
      surfaceContainerHigh: step(.11),
      surfaceContainerHighest: step(.14),
      outlineVariant: step(.18),
      secondaryContainer: hexColor(colors, 'selection') ?? step(.2),
      error: hexColor(colors, 'red') ?? scheme.error,
    );
  }
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  final sizes = Corners(radius);
  final control = BorderRadius.circular(sizes.control), small = BorderRadius.circular(sizes.small);
  final controlShape = RoundedRectangleBorder(borderRadius: control);
  final fg = scheme.onSurface, accent = scheme.primary;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [
      sizes,
      markColorsFrom(colors),
    ],
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(shape: shape),
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radius))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)))),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)))),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderRadius: control),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      isDense: true,
      border: OutlineInputBorder(borderRadius: control, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: control, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: control, borderSide: BorderSide(color: accent, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: control, borderSide: BorderSide(color: scheme.error)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: control, borderSide: BorderSide(color: scheme.error, width: 1.5)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: scheme.inverseSurface.withValues(alpha: .92), borderRadius: control),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: scheme.onSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: controlShape)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: controlShape)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: controlShape)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: controlShape)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(shape: controlShape)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: controlShape)),
    chipTheme: ChipThemeData(shape: controlShape),
    listTileTheme: ListTileThemeData(shape: controlShape),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: small)),
    progressIndicatorTheme: ProgressIndicatorThemeData(borderRadius: small),
    // Square squares the slider too, but keeps its knob small (no block).
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: accent,
      inactiveTrackColor: fg.withValues(alpha: .15),
      thumbColor: accent,
      trackShape: radius <= 0 ? const RectangularSliderTrackShape() : const RoundedRectSliderTrackShape(),
      thumbShape: KnobShape(square: radius <= 0),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
    ),
  );
}

/// The slider's knob: 14 px, round, or square with Square corners (not a big block).
class KnobShape extends SliderComponentShape {
  const KnobShape({this.square = false});
  final bool square;
  static const _side = 14.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.square(_side);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final paint = Paint()..color = sliderTheme.thumbColor ?? Colors.grey;
    final box = Rect.fromCenter(center: center, width: _side, height: _side);
    square ? context.canvas.drawRect(box, paint) : context.canvas.drawOval(box, paint);
  }
}
