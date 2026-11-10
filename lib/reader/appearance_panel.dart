import 'package:flutter/material.dart';

import '../app/reader_settings.dart';
import '../theme/reader_theme.dart';

/// "Aa" button in the reader's app bar, opening the appearance panel.
class AppearanceButton extends StatelessWidget {
  const AppearanceButton({super.key, required this.settings});

  final ReaderSettings settings;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    return MenuAnchor(
      alignmentOffset: const Offset(-AppearancePanel.width + 40, 4),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(reader.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: reader.divider),
          ),
        ),
      ),
      menuChildren: [AppearancePanel(settings: settings)],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Appearance',
        icon: const Icon(Icons.text_format),
        isSelected: controller.isOpen,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Theme, font, size, line spacing and alignment controls.
class AppearancePanel extends StatelessWidget {
  const AppearancePanel({super.key, required this.settings});

  final ReaderSettings settings;

  static const width = 400.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(theme, 'Theme'),
              SegmentedButton<ReaderThemeMode>(
                showSelectedIcon: false,
                segments: [
                  for (final mode in ReaderThemeMode.values)
                    ButtonSegment(
                      value: mode,
                      label: Text(mode.label),
                      icon: _Swatch(mode: mode),
                    ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) => settings.themeMode = s.first,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
              const SizedBox(height: 16),
              _label(theme, 'Font'),
              SegmentedButton<ReaderFont>(
                showSelectedIcon: false,
                segments: [
                  for (final font in ReaderFont.values)
                    ButtonSegment(
                      value: font,
                      label: Text(
                        font.label,
                        style: TextStyle(fontFamily: font.family),
                      ),
                    ),
                ],
                selected: {settings.font},
                onSelectionChanged: (s) => settings.font = s.first,
              ),
              const SizedBox(height: 12),
              _Stepper(
                label: 'Text size',
                value: settings.fontSize.round().toString(),
                onDecrease: settings.canDecreaseFont
                    ? () => settings.changeFontSize(-1)
                    : null,
                onIncrease: settings.canIncreaseFont
                    ? () => settings.changeFontSize(1)
                    : null,
                decreaseIcon: Icons.text_decrease,
                increaseIcon: Icons.text_increase,
              ),
              _Stepper(
                label: 'Line spacing',
                value: settings.lineHeight.toStringAsFixed(2),
                onDecrease: settings.canDecreaseLineHeight
                    ? () => settings.changeLineHeight(-0.1)
                    : null,
                onIncrease: settings.canIncreaseLineHeight
                    ? () => settings.changeLineHeight(0.1)
                    : null,
                decreaseIcon: Icons.density_small,
                increaseIcon: Icons.density_large,
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Justify text',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Switch(
                    value: settings.justify,
                    onChanged: (v) => settings.justify = v,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: theme.textTheme.labelLarge),
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    required this.decreaseIcon,
    required this.increaseIcon,
  });

  final String label;
  final String value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final IconData decreaseIcon;
  final IconData increaseIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        IconButton.outlined(
          tooltip: 'Decrease ${label.toLowerCase()}',
          onPressed: onDecrease,
          icon: Icon(decreaseIcon, size: 18),
        ),
        SizedBox(
          width: 48,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall,
          ),
        ),
        IconButton.outlined(
          tooltip: 'Increase ${label.toLowerCase()}',
          onPressed: onIncrease,
          icon: Icon(increaseIcon, size: 18),
        ),
      ],
    );
  }
}

/// Little two-tone circle previewing a theme.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.mode});

  final ReaderThemeMode mode;

  @override
  Widget build(BuildContext context) {
    final a = ReaderTheme.forMode(mode, Brightness.light);
    final b = ReaderTheme.forMode(mode, Brightness.dark);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: a.secondaryText.withValues(alpha: 0.5)),
        gradient: LinearGradient(
          colors: [a.background, a.background, b.background, b.background],
          stops: const [0, 0.5, 0.5, 1],
        ),
      ),
    );
  }
}
