import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('settings are persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await ReaderSettings.load();
    expect(settings.themeMode, ReaderThemeMode.auto);
    expect(settings.fontSize, ReaderSettings.defaultFontSize);

    settings
      ..themeMode = ReaderThemeMode.sepia
      ..font = ReaderFont.sans
      ..justify = true
      ..changeFontSize(3)
      ..changeLineHeight(0.1);

    final reloaded = await ReaderSettings.load();
    expect(reloaded.themeMode, ReaderThemeMode.sepia);
    expect(reloaded.font, ReaderFont.sans);
    expect(reloaded.justify, isTrue);
    expect(reloaded.fontSize, ReaderSettings.defaultFontSize + 3);
    expect(
      reloaded.lineHeight,
      closeTo(ReaderSettings.defaultLineHeight + 0.1, 1e-9),
    );
  });

  test('font size and line height are clamped', () {
    final settings = ReaderSettings.memory();
    for (var i = 0; i < 50; i++) {
      settings
        ..changeFontSize(1)
        ..changeLineHeight(0.1);
    }
    expect(settings.fontSize, ReaderSettings.maxFontSize);
    expect(settings.lineHeight, ReaderSettings.maxLineHeight);
    expect(settings.canIncreaseFont, isFalse);
  });

  test('auto theme follows the system brightness', () {
    expect(
      ReaderTheme.forMode(ReaderThemeMode.auto, Brightness.dark),
      ReaderTheme.dark,
    );
    expect(
      ReaderTheme.forMode(ReaderThemeMode.auto, Brightness.light),
      ReaderTheme.light,
    );
    expect(
      ReaderTheme.forMode(ReaderThemeMode.sepia, Brightness.dark),
      ReaderTheme.sepia,
    );
  });
}
