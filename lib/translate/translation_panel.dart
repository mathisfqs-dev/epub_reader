import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dictionary/word_info_view.dart';
import '../theme/reader_theme.dart';
import 'languages.dart';
import 'translation_controller.dart';
import 'translation_model.dart';

/// Right side panel of the reader: the original text, its translation as it
/// streams in, the target language, copy and retry.
class TranslationPanel extends StatelessWidget {
  const TranslationPanel({
    super.key,
    required this.controller,
    this.fontFamily,
    this.fontSize = 17,
  });

  static const width = 380.0;

  final TranslationController controller;
  final String? fontFamily;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    return Material(
      color: reader.surface,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final request = controller.request;
          if (request == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(controller: controller),
              Divider(height: 1, color: reader.divider),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Text(
                    request.text,
                    style: TextStyle(
                      color: reader.secondaryText,
                      fontFamily: fontFamily,
                      fontSize: fontSize * 0.85,
                      fontStyle: FontStyle.italic,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
              if (controller.truncated)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Long selection: only its beginning is translated.',
                    style: TextStyle(color: reader.secondaryText, fontSize: 12),
                  ),
                ),
              Divider(height: 1, color: reader.divider),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (controller.word != null) ...[
                        WordInfoView(
                          controller: controller,
                          fontFamily: fontFamily,
                          fontSize: fontSize,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'In this sentence',
                          style: TextStyle(
                            color: reader.secondaryText,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      TranslationBody(
                        controller: controller,
                        style: TextStyle(
                          color: reader.text,
                          fontFamily: fontFamily,
                          fontSize: fontSize,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: reader.divider),
              _Footer(controller: controller),
              _AutoTranslateSwitch(controller: controller),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final TranslationController controller;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final theme = Theme.of(context);
    final source = TranslationLanguage.of(controller.source);
    final target = TranslationLanguage.of(controller.target);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.translate, size: 20, color: reader.accent),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              source.label,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.arrow_forward,
              size: 16,
              color: reader.secondaryText,
            ),
          ),
          Flexible(
            child: PopupMenuButton<String>(
              tooltip: 'Translate into',
              initialValue: target.code,
              onSelected: (code) => controller.target = code,
              itemBuilder: (context) => [
                for (final l in TranslationLanguage.all)
                  if (l.code != controller.source)
                    PopupMenuItem(value: l.code, child: Text(l.label)),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        target.label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: reader.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, color: reader.accent),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Close translation',
            icon: const Icon(Icons.close),
            onPressed: controller.close,
          ),
        ],
      ),
    );
  }
}

/// The translation as it streams in, or its progress, error or the model to
/// install.
class TranslationBody extends StatelessWidget {
  const TranslationBody({
    super.key,
    required this.controller,
    required this.style,
  });

  final TranslationController controller;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final secondary = TextStyle(color: reader.secondaryText, height: 1.45);
    switch (controller.phase) {
      case TranslationPhase.needsModel:
        return _InstallModel(model: controller.model);
      case TranslationPhase.starting:
        return Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                controller.model.isStarting
                    ? 'Loading the translation model… (a few seconds)'
                    : 'Translating…',
                style: secondary,
              ),
            ),
          ],
        );
      case TranslationPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.output.isNotEmpty) ...[
              SelectableText(controller.output, style: style),
              const SizedBox(height: 16),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 18, color: reader.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    controller.error ?? 'Translation failed.',
                    style: secondary,
                  ),
                ),
              ],
            ),
          ],
        );
      case TranslationPhase.streaming:
      case TranslationPhase.done:
        return SelectableText(controller.output, style: style);
    }
  }
}

class _InstallModel extends StatelessWidget {
  const _InstallModel({required this.model});

  final TranslationModel model;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final secondary = TextStyle(color: reader.secondaryText, height: 1.45);
    final downloading = model.status == LlmFileStatus.downloading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Translation runs on this Mac with ${model.displayName}. '
          'The model (${model.approximateSize}) is downloaded once.',
          style: secondary,
        ),
        const SizedBox(height: 16),
        if (downloading) ...[
          LinearProgressIndicator(value: model.progress),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                model.progress == null
                    ? 'Downloading…'
                    : 'Downloading… ${(model.progress! * 100).toStringAsFixed(0)} %',
                style: secondary,
              ),
              const Spacer(),
              TextButton(
                onPressed: model.cancelDownload,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ] else ...[
          if (model.status == LlmFileStatus.failed) ...[
            Text('Download failed: ${model.error}', style: secondary),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: model.download,
            icon: const Icon(Icons.download),
            label: Text('Download the model (${model.approximateSize})'),
          ),
        ],
      ],
    );
  }
}

/// "Auto-translate selection": new selections are translated without
/// clicking "Translate" while the panel is open.
class _AutoTranslateSwitch extends StatelessWidget {
  const _AutoTranslateSwitch({required this.controller});

  final TranslationController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Auto-translate selection',
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Switch(
              value: settings.autoTranslateSelection,
              onChanged: (v) => settings.autoTranslateSelection = v,
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatefulWidget {
  const _Footer({required this.controller});

  final TranslationController controller;

  @override
  State<_Footer> createState() => _FooterState();
}

class _FooterState extends State<_Footer> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.controller.output));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final canCopy = c.output.isNotEmpty && c.phase == TranslationPhase.done;
    final canRetry =
        c.phase == TranslationPhase.done || c.phase == TranslationPhase.failed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: TextButton.icon(
              onPressed: canCopy ? _copy : null,
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
              label: Text(
                _copied ? 'Copied' : 'Copy',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Flexible(
            child: TextButton.icon(
              onPressed: canRetry ? c.retry : null,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text(
                'Translate again',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
