import 'package:flutter/material.dart';

import '../theme/reader_theme.dart';
import '../translate/translation_controller.dart';
import 'dictionaries.dart';
import 'grammar_labels.dart';
import 'word_lookup.dart';

/// The dictionary's analysis of the word translated in the side panel: its
/// base form, grammar and definitions, or the dictionary to install.
class WordInfoView extends StatelessWidget {
  const WordInfoView({
    super.key,
    required this.controller,
    this.fontFamily,
    this.fontSize = 17,
  });

  final TranslationController controller;
  final String? fontFamily;
  final double fontSize;

  static const _languageNames = {'de': 'German', 'es': 'Spanish'};

  @override
  Widget build(BuildContext context) {
    final dictionaries = controller.dictionaries!;
    final language = controller.source;
    final reader = ReaderTheme.of(context);
    final secondary = TextStyle(color: reader.secondaryText, height: 1.45);
    switch (dictionaries.status(language)) {
      case DictionaryStatus.unsupported:
        return const SizedBox.shrink();
      case DictionaryStatus.missing:
      case DictionaryStatus.failed:
        return _Install(
          dictionaries: dictionaries,
          language: language,
          name: _languageNames[language] ?? language,
        );
      case DictionaryStatus.installing:
        final progress = dictionaries.progress(language);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress == null
                        ? 'Installing the dictionary…'
                        : 'Installing the dictionary… '
                              '${(progress * 100).toStringAsFixed(0)} %',
                    style: secondary,
                  ),
                ),
                TextButton(
                  onPressed: () => dictionaries.cancel(language),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      case DictionaryStatus.ready:
        break;
    }
    final analyses = controller.analyses;
    if (controller.wordError != null) {
      return Text(controller.wordError!, style: secondary);
    }
    if (analyses == null) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (analyses.isEmpty) {
      return Text(
        '“${controller.word}” is not in the dictionary.',
        style: secondary,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, a) in analyses.indexed) ...[
          if (i > 0) const SizedBox(height: 14),
          _Analysis(
            analysis: a,
            language: language,
            fontFamily: fontFamily,
            fontSize: fontSize,
          ),
        ],
      ],
    );
  }
}

class _Analysis extends StatelessWidget {
  const _Analysis({
    required this.analysis,
    required this.language,
    this.fontFamily,
    required this.fontSize,
  });

  final WordAnalysis analysis;
  final String language;
  final String? fontFamily;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final a = analysis;
    final entry = a.entry;
    final gender = entry?.gender;
    final article = a.pos == 'noun'
        ? GrammarLabels.article(language, gender)
        : null;
    final kind = [
      GrammarLabels.pos(a.pos),
      if (gender != null) GrammarLabels.gender(gender),
    ].join(', ');
    final definitions = (entry?.french.isNotEmpty ?? false)
        ? entry!.french
        : entry?.english ?? const <String>[];
    final small = TextStyle(
      color: reader.secondaryText,
      fontSize: fontSize * 0.75,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (a.note != null)
          Text(
            a.note!,
            style: small.copyWith(
              color: reader.accent,
              fontStyle: FontStyle.italic,
            ),
          ),
        SelectableText.rich(
          TextSpan(
            children: [
              if (article != null) TextSpan(text: '$article '),
              TextSpan(
                text: a.lemma,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(
                text: '  $kind',
                style: small.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
          ),
          style: TextStyle(
            color: reader.text,
            fontFamily: fontFamily,
            fontSize: fontSize,
          ),
        ),
        for (final line in GrammarLabels.describe(a.tagSets, pos: a.pos))
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SelectableText(line, style: small),
          ),
        if (definitions.isNotEmpty) const SizedBox(height: 4),
        for (final (i, d) in definitions.take(3).indexed)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SelectableText(
              definitions.length == 1 ? d : '${i + 1}. $d',
              style: TextStyle(
                color: reader.text,
                fontFamily: fontFamily,
                fontSize: fontSize * 0.85,
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }
}

class _Install extends StatelessWidget {
  const _Install({
    required this.dictionaries,
    required this.language,
    required this.name,
  });

  final Dictionaries dictionaries;
  final String language;
  final String name;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final secondary = TextStyle(color: reader.secondaryText, height: 1.45);
    final error = dictionaries.error(language);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Install the offline $name dictionary (Wiktionary) to see the base '
          'form, grammar and definitions of a word. About '
          '${dictionaries.approximateSize(language)} is downloaded, then '
          'prepared on this Mac in about a minute.',
          style: secondary,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error, style: secondary.copyWith(color: reader.accent)),
        ],
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: () => dictionaries.install(language),
          icon: const Icon(Icons.menu_book_outlined),
          label: Text('Install the $name dictionary'),
        ),
      ],
    );
  }
}
