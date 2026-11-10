import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../theme/reader_theme.dart';
import '../tts/kokoro_model.dart';
import '../tts/pocket_model.dart';
import '../tts/speech_models.dart';
import '../tts/voice.dart';

/// Offers to install [model] (download for Kokoro, a folder for Pocket TTS).
/// Returns true once it is installed and the user wants to start reading.
Future<bool> showVoiceModelDialog(
  BuildContext context,
  VoiceModel model,
) async {
  if (model.isReady) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => _InstallDialog(model: model),
  );
  return ok == true && model.isReady;
}

class _InstallDialog extends StatelessWidget {
  const _InstallDialog({required this.model});

  final VoiceModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final busy = switch (model) {
          final KokoroModel k => k.isBusy,
          final PocketModel p => p.isBusy,
          _ => false,
        };
        return AlertDialog(
          icon: const Icon(Icons.record_voice_over_outlined),
          title: const Text('Read aloud'),
          content: SizedBox(width: 400, child: VoiceModelPanel(model: model)),
          actions: [
            if (!busy)
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(model.isReady ? 'Close' : 'Not now'),
              ),
            if (model.isReady)
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start reading'),
              ),
          ],
        );
      },
    );
  }
}

/// Status of a model with the button that installs it.
class VoiceModelPanel extends StatelessWidget {
  const VoiceModelPanel({super.key, required this.model});

  final VoiceModel model;

  @override
  Widget build(BuildContext context) => switch (model) {
    final KokoroModel k => _KokoroPanel(model: k),
    final PocketModel p => _PocketPanel(model: p),
    _ => const SizedBox.shrink(),
  };
}

class _KokoroPanel extends StatelessWidget {
  const _KokoroPanel({required this.model});

  final KokoroModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final status = model.status;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(switch (status) {
              ModelStatus.ready => 'The voices are installed.',
              ModelStatus.downloading => 'Downloading the voices…',
              ModelStatus.extracting => 'Installing…',
              _ =>
                'Reading aloud uses Kokoro, an open-source voice model '
                    'that runs on this Mac. It needs a one-time download '
                    'of about ${KokoroModel.approximateSize}.',
            }),
            if (model.isBusy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: status == ModelStatus.downloading
                    ? model.progress
                    : null,
              ),
              if (status == ModelStatus.downloading &&
                  model.progress != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${(model.progress! * 100).round()} %',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
            if (status == ModelStatus.failed) ...[
              const SizedBox(height: 12),
              Text(
                'Download failed: ${model.error}',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (status == ModelStatus.downloading) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: model.cancelDownload,
                child: const Text('Cancel download'),
              ),
            ] else if (!model.isBusy && !model.isReady) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: model.download,
                icon: const Icon(Icons.download),
                label: Text(
                  status == ModelStatus.failed
                      ? 'Try again'
                      : 'Download (${KokoroModel.approximateSize})',
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PocketPanel extends StatelessWidget {
  const _PocketPanel({required this.model});

  final PocketModel model;

  Future<void> _install(BuildContext context) async {
    final folder = await getDirectoryPath(confirmButtonText: 'Install');
    if (folder == null) return;
    final installed = await model.installFrom(folder);
    if (installed.isEmpty || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Pocket TTS installed: '
          '${installed.map((l) => pocketLanguageNames[l] ?? l).join(', ')}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reader = ReaderTheme.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final packs = model.packs;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (packs.isEmpty)
              Text(
                'Pocket TTS (Kyutai) runs on this Mac too. Its models are '
                'made with pocket_tts_export and installed from a folder: '
                'pick one model (pocket-french-int8…) or the folder that '
                'holds them (pocket_tts_export/out). About '
                '${PocketModel.approximateSizePerLanguage} per language.',
              )
            else
              for (final pack in packs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.check, size: 18, color: reader.accent),
                      const SizedBox(width: 8),
                      Text(pack.languageName, style: theme.textTheme.bodyLarge),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          pack.voices
                              .map((v) => v.description.split(' · ').first)
                              .join(', '),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: reader.secondaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            if (model.isBusy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Text('Installing…', style: theme.textTheme.bodySmall),
            ],
            if (model.error != null && !model.isBusy) ...[
              const SizedBox(height: 12),
              Text(
                model.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (!model.isBusy) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _install(context),
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(
                  packs.isEmpty
                      ? 'Install from a folder…'
                      : 'Add or update languages…',
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Lets the user choose the read-aloud model (and install it).
Future<void> showSpeechModelPicker(BuildContext context, SpeechModels models) =>
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: models,
        builder: (context, _) => AlertDialog(
          icon: const Icon(Icons.record_voice_over_outlined),
          title: const Text('Read-aloud voices'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final kind in TtsModelKind.values) ...[
                    _ModelCard(
                      kind: kind,
                      model: models.modelOf(kind),
                      selected: models.activeKind == kind,
                      onSelect: () => models.select(kind),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.kind,
    required this.model,
    required this.selected,
    required this.onSelect,
  });

  final TtsModelKind kind;
  final VoiceModel model;
  final bool selected;
  final VoidCallback onSelect;

  String get _summary => switch (kind) {
    TtsModelKind.kokoro =>
      'Many voices · English, Français, Español, Italiano, Português, '
          'Hindi · speed control',
    TtsModelKind.pocket =>
      'Kyutai · more natural, expressive voices · English, Français, '
          'Deutsch, Español · no speed control yet',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reader = ReaderTheme.of(context);
    return Material(
      color: selected
          ? reader.accent.withValues(alpha: 0.10)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? reader.accent : reader.divider,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? reader.accent : reader.secondaryText,
                semanticLabel: selected ? 'selected' : 'not selected',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(kind.label, style: theme.textTheme.titleMedium),
                        const Spacer(),
                        if (selected)
                          Text(
                            'In use',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: reader.accent,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: reader.secondaryText,
                      ),
                    ),
                    const SizedBox(height: 12),
                    VoiceModelPanel(model: model),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Home screen button showing the read-aloud model in use; opens
/// [showSpeechModelPicker].
class SpeechModelButton extends StatelessWidget {
  const SpeechModelButton({super.key, required this.models});

  final SpeechModels models;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: models,
      builder: (context, _) => Tooltip(
        message: 'Choose the read-aloud voice model',
        child: OutlinedButton.icon(
          onPressed: () => showSpeechModelPicker(context, models),
          icon: Icon(
            models.active.isReady
                ? Icons.record_voice_over_outlined
                : Icons.download_outlined,
          ),
          label: Text('Voice: ${models.activeKind.label}'),
        ),
      ),
    );
  }
}
