import 'package:flutter/material.dart';

/// Which reader theme is selected. [auto] follows the system light/dark mode.
enum ReaderThemeMode {
  auto('Auto'),
  light('Light'),
  sepia('Sepia'),
  dark('Dark');

  const ReaderThemeMode(this.label);
  final String label;
}

/// Colors of the reading surface. The whole app is themed from it.
@immutable
class ReaderTheme extends ThemeExtension<ReaderTheme> {
  const ReaderTheme({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.text,
    required this.secondaryText,
    required this.accent,
    required this.selection,
    required this.highlight,
    required this.divider,
  });

  final Brightness brightness;

  /// Page background.
  final Color background;

  /// App bar, panels, cards.
  final Color surface;
  final Color text;

  /// Captions, footnotes, metadata.
  final Color secondaryText;

  /// Links and buttons.
  final Color accent;
  final Color selection;

  /// Background of the sentence being read aloud (M6).
  final Color highlight;
  final Color divider;

  static const light = ReaderTheme(
    brightness: Brightness.light,
    background: Color(0xFFFBFAF8),
    surface: Color(0xFFF1EEE9),
    text: Color(0xFF1E1C1A),
    secondaryText: Color(0xFF6B6660),
    accent: Color(0xFF8A4B2A),
    selection: Color(0x408A4B2A),
    highlight: Color(0xFFFFEAA8),
    divider: Color(0xFFDDD8D0),
  );

  static const sepia = ReaderTheme(
    brightness: Brightness.light,
    background: Color(0xFFF4ECD8),
    surface: Color(0xFFEADFC6),
    text: Color(0xFF4A3B2A),
    secondaryText: Color(0xFF7D6A55),
    accent: Color(0xFF9C5A2E),
    selection: Color(0x509C5A2E),
    highlight: Color(0xFFF0D48A),
    divider: Color(0xFFD8C8A8),
  );

  static const dark = ReaderTheme(
    brightness: Brightness.dark,
    background: Color(0xFF16161A),
    surface: Color(0xFF212126),
    text: Color(0xFFDAD8D3),
    secondaryText: Color(0xFF9A9893),
    accent: Color(0xFFD8A273),
    selection: Color(0x55D8A273),
    highlight: Color(0xFF4D4222),
    divider: Color(0xFF34343B),
  );

  static ReaderTheme of(BuildContext context) =>
      Theme.of(context).extension<ReaderTheme>() ?? light;

  static ReaderTheme forMode(ReaderThemeMode mode, Brightness platform) =>
      switch (mode) {
        ReaderThemeMode.auto => platform == Brightness.dark ? dark : light,
        ReaderThemeMode.light => light,
        ReaderThemeMode.sepia => sepia,
        ReaderThemeMode.dark => dark,
      };

  ThemeData toThemeData() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          surface: surface,
          onSurface: text,
          onSurfaceVariant: secondaryText,
          outlineVariant: divider,
        );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      drawerTheme: DrawerThemeData(backgroundColor: surface),
      dividerTheme: DividerThemeData(color: divider),
      textSelectionTheme: TextSelectionThemeData(selectionColor: selection),
      extensions: [this],
    );
  }

  @override
  ReaderTheme copyWith({
    Brightness? brightness,
    Color? background,
    Color? surface,
    Color? text,
    Color? secondaryText,
    Color? accent,
    Color? selection,
    Color? highlight,
    Color? divider,
  }) => ReaderTheme(
    brightness: brightness ?? this.brightness,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    text: text ?? this.text,
    secondaryText: secondaryText ?? this.secondaryText,
    accent: accent ?? this.accent,
    selection: selection ?? this.selection,
    highlight: highlight ?? this.highlight,
    divider: divider ?? this.divider,
  );

  @override
  ReaderTheme lerp(ReaderTheme? other, double t) {
    if (other == null) return this;
    return ReaderTheme(
      brightness: t < 0.5 ? brightness : other.brightness,
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      text: Color.lerp(text, other.text, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
    );
  }
}
