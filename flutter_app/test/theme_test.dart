// The marks' colours must stay apart: the shortcut key map tells free,
// yours and desktop-default keys apart by them alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/theme.dart';

void main() {
  test('a palette with distinct green, orange and yellow is used as is', () {
    final marks = markColorsFrom({'green': '#8ff0a4', 'orange': '#ffa348', 'yellow': '#f8e45c'});
    expect(marks.running, const Color(0xff8ff0a4));
    expect(marks.update, const Color(0xffffa348));
    expect(marks.fresh, const Color(0xfff8e45c));
  });

  test('a KDE scheme whose positive and neutral are orange falls back to the default trio', () {
    // MaprismaA: ForegroundPositive 255,159,10; ForegroundNeutral 255,194,122.
    final marks = markColorsFrom({'green': '#ff9f0a', 'orange': '#ffa348', 'yellow': '#ffc27a'});
    expect(marks.running, const Color(0xff3a944a));
    expect(marks.update, const Color(0xffed5b00));
    expect(marks.fresh, const Color(0xffc88800));
  });

  test('missing colours use the defaults', () {
    final marks = markColorsFrom({});
    expect(marks.running, const Color(0xff3a944a));
  });
}
