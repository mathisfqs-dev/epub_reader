import 'package:flutter/material.dart';

import '../app/reader_settings.dart';
import '../theme/reader_theme.dart';
import '../translate/languages.dart';
import '../translate/read_aloud_translation.dart';
import '../translate/translation_panel.dart';
import '../tts/read_aloud_controller.dart';
import '../tts/voice.dart';

/// Player controls shown at the bottom of the reader while reading aloud,
/// with, when [translation] is given, a menu to translate the sentence read
/// (when paused or every sentence), shown under the controls.
class ReadAloudBar extends StatelessWidget {
  const ReadAloudBar({
    super.key,
    required this.controller,
    required this.settings,
    required this.language,
    required this.model,
    this.translation,
  });

  final ReadAloudController controller;
  final ReaderSettings settings;

  /// Model whose voices are offered.
  final VoiceModel model;

  /// Language of the book (`en`, `fr`…), whose voices are listed first.
  final String language;

  final ReadAloudTranslation? translation;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final theme = Theme.of(context);
    final translation = this.translation;
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        if (translation != null) ...[settings, translation.translation],
      ]),
      builder: (context, _) {
        final state = controller.state;
        final loading = state == ReadAloudState.loading;
        final playing = state == ReadAloudState.playing;
        return Material(
          color: reader.surface,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: reader.divider)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous sentence',
                          icon: const Icon(Icons.skip_previous),
                          onPressed: controller.previous,
                        ),
                        SizedBox.square(
                          dimension: 48,
                          child: loading
                              ? Tooltip(
                                  message: 'Preparing voice…',
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: reader.accent,
                                    ),
                                  ),
                                )
                              : IconButton.filled(
                                  tooltip: playing ? 'Pause' : 'Play',
                                  icon: Icon(
                                    playing ? Icons.pause : Icons.play_arrow,
                                  ),
                                  onPressed: controller.togglePause,
                                ),
                        ),
                        IconButton(
                          tooltip: 'Next sentence',
                          icon: const Icon(Icons.skip_next),
                          onPressed: controller.next,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            controller.error ??
                                (controller.current?.isTitle == true &&
                                        state == ReadAloudState.playing
                                    ? 'Chapter: ${controller.textOf(controller.current!)}'
                                    : _status(state)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: controller.error != null
                                  ? theme.colorScheme.error
                                  : reader.secondaryText,
                            ),
                          ),
                        ),
                        if (translation != null)
                          _TranslateToggle(
                            settings: settings,
                            translation: translation,
                          ),
                        _VoiceButton(
                          voice: controller.voice,
                          voices: model.voicesFor(language),
                          onSelected: (v) {
                            settings.setVoice(language, v);
                            controller.voice = v;
                          },
                        ),
                        if (model.supportsSpeed)
                          _SpeedButton(
                            speed: controller.speed,
                            onSelected: (s) {
                              settings.speechSpeed = s;
                              controller.speed = s;
                            },
                          ),
                        IconButton(
                          tooltip: 'Stop reading',
                          icon: const Icon(Icons.close),
                          onPressed: controller.stop,
                        ),
                      ],
                    ),
                    if (translation != null && translation.translation.isOpen)
                      _TranslationArea(
                        translation: translation,
                        settings: settings,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _status(ReadAloudState state) => switch (state) {
    ReadAloudState.loading => 'Preparing…',
    ReadAloudState.playing => 'Reading aloud',
    ReadAloudState.paused => 'Paused',
    ReadAloudState.stopped => '',
  };
}

class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.voice,
    required this.voices,
    required this.onSelected,
  });

  final Voice voice;

  /// The book's language first.
  final List<Voice> voices;
  final ValueChanged<Voice> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Voice>(
      tooltip: 'Voice',
      initialValue: voice,
      onSelected: onSelected,
      constraints: const BoxConstraints(maxHeight: 420, minWidth: 220),
      itemBuilder: (context) => [
        for (final (i, v) in voices.indexed) ...[
          if (i > 0 && v.language != voices[i - 1].language)
            const PopupMenuDivider(),
          PopupMenuItem(
            value: v,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: v == voice ? const Icon(Icons.check, size: 18) : null,
                ),
                Expanded(child: Text(v.description)),
                _GenderIcon(v),
              ],
            ),
          ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.record_voice_over_outlined, size: 20),
            const SizedBox(width: 6),
            Text(voice.description),
            const SizedBox(width: 2),
            _GenderIcon(voice),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _GenderIcon extends StatelessWidget {
  const _GenderIcon(this.voice);

  final Voice voice;

  @override
  Widget build(BuildContext context) => switch (voice.female) {
    null => const SizedBox.shrink(),
    final female => Icon(
      female ? Icons.female : Icons.male,
      size: 16,
      semanticLabel: female ? 'female voice' : 'male voice',
      color: ReaderTheme.of(context).secondaryText,
    ),
  };
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onSelected});

  final double speed;
  final ValueChanged<double> onSelected;

  static String label(double s) => '${s.toStringAsFixed(1)}×';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Reading speed',
      initialValue: speed,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final s in ReaderSettings.speechSpeeds)
          PopupMenuItem(value: s, child: Text(label(s))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 20),
            const SizedBox(width: 6),
            Text(label(speed)),
          ],
        ),
      ),
    );
  }
}

/// Chooses when the sentence read aloud is translated (off, when paused,
/// every sentence) and, when on, into which language.
class _TranslateToggle extends StatelessWidget {
  const _TranslateToggle({required this.settings, required this.translation});

  final ReaderSettings settings;
  final ReadAloudTranslation translation;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final mode = settings.readAloudTranslation;
    final on = mode != ReadAloudTranslateMode.off;
    final controller = translation.translation;
    final target = TranslationLanguage.of(controller.target);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<ReadAloudTranslateMode>(
          tooltip: 'Translate while reading',
          initialValue: mode,
          onSelected: (m) => settings.readAloudTranslation = m,
          itemBuilder: (context) => [
            for (final m in ReadAloudTranslateMode.values)
              PopupMenuItem(
                value: m,
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: m == mode
                          ? const Icon(Icons.check, size: 18)
                          : null,
                    ),
                    Text(m.label),
                  ],
                ),
              ),
          ],
          icon: on
              ? Icon(Icons.translate, color: reader.accent)
              : const Icon(Icons.translate_outlined),
        ),
        if (on)
          PopupMenuButton<String>(
            tooltip: 'Translate into',
            initialValue: target.code,
            onSelected: (code) => controller.target = code,
            itemBuilder: (context) => [
              for (final l in TranslationLanguage.all)
                if (l.code != controller.source)
                  PopupMenuItem(value: l.code, child: Text(l.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 4, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    target.label,
                    style: TextStyle(
                      color: reader.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: reader.accent),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The translation of the sentence read, under the controls.
class _TranslationArea extends StatelessWidget {
  const _TranslationArea({required this.translation, required this.settings});

  final ReadAloudTranslation translation;
  final ReaderSettings settings;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: reader.divider),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TranslationBody(
              controller: translation.translation,
              style: TextStyle(
                color: reader.text,
                fontFamily: settings.font.family,
                fontSize: settings.fontSize * 0.85,
                height: 1.45,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
