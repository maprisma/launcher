import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/theme.dart';

/// Settings › Corners in Maprisma Playground's three sizes.
void main() {
  test('the choices: like windows, slightly rounded 6, rounded 12, square 0', () {
    expect(cornerRadius('windows', 10), 10);
    expect(cornerRadius('windows', null), 12);
    expect(cornerRadius('slight', 20), 6);
    expect(cornerRadius('rounded', 0), 12);
    expect(cornerRadius('square', 12), 0);
    expect(cornerRadius('unknown', 4), 4);
  });

  test('three sizes: cards and dialogs the radius, controls at most 8, small parts at most 4', () {
    expect((const Corners(12).control, const Corners(12).small), (8, 4));
    expect((const Corners(6).control, const Corners(6).small), (6, 4));
    expect((const Corners(0).control, const Corners(0).small), (0, 0));
  });

  BorderRadius? radiusOf(OutlinedBorder? shape) => (shape as RoundedRectangleBorder?)?.borderRadius as BorderRadius?;

  test('every control follows: buttons, fields, check boxes, progress, tooltips, dialogs, menus, cards', () {
    for (final r in [0.0, 6.0, 12.0]) {
      final theme = appTheme(Brightness.dark, const {}, r);
      final control = BorderRadius.circular(r < 8 ? r : 8), small = BorderRadius.circular(r < 4 ? r : 4);
      final whole = BorderRadius.circular(r);
      final states = <WidgetState>{};
      expect(radiusOf(theme.textButtonTheme.style!.shape!.resolve(states)), control);
      expect(radiusOf(theme.outlinedButtonTheme.style!.shape!.resolve(states)), control);
      expect(radiusOf(theme.filledButtonTheme.style!.shape!.resolve(states)), control);
      expect(radiusOf(theme.elevatedButtonTheme.style!.shape!.resolve(states)), control);
      expect(radiusOf(theme.iconButtonTheme.style!.shape!.resolve(states)), control);
      expect((theme.inputDecorationTheme.border as OutlineInputBorder).borderRadius, control);
      expect((theme.inputDecorationTheme.focusedBorder as OutlineInputBorder).borderRadius, control);
      expect(radiusOf(theme.checkboxTheme.shape), small);
      expect(theme.progressIndicatorTheme.borderRadius, small);
      expect((theme.tooltipTheme.decoration as BoxDecoration).borderRadius, control);
      expect(radiusOf(theme.dialogTheme.shape as OutlinedBorder?), whole);
      expect(radiusOf(theme.popupMenuTheme.shape as OutlinedBorder?), whole);
      expect(radiusOf(theme.cardTheme.shape as OutlinedBorder?), whole);
      expect(theme.extension<Corners>()!.radius, r);
      final knob = theme.sliderTheme.thumbShape as KnobShape;
      expect(knob.square, r == 0);
      expect(knob.getPreferredSize(true, false), const Size.square(14)); // no big block when square
      expect(theme.sliderTheme.trackShape, r == 0 ? isA<RectangularSliderTrackShape>() : isA<RoundedRectSliderTrackShape>());
    }
  });
}
