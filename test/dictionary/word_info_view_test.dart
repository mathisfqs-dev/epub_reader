import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/dictionary/dictionary_index.dart';
import 'package:epub_reader/dictionary/word_lookup.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:epub_reader/translate/translation_controller.dart';
import 'package:epub_reader/translate/translation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../translate/fakes.dart';
import 'fixtures.dart';

void main() {
  const sentence = 'Er hob den Stein auf und warf ihn weg.';

  const heben = WordAnalysis(
    lemma: 'heben',
    pos: 'verb',
    tagSets: [
      ['indicative', 'preterite', 'singular', 'third-person'],
    ],
    entry: DictionaryEntry(
      lemma: 'heben',
      pos: 'verb',
      french: ['Soulever, élever.'],
    ),
  );
  final answers = {
    'hob|$sentence': [
      const WordAnalysis(
        lemma: 'aufheben',
        pos: 'verb',
        note: 'hob … auf',
        tagSets: [
          ['indicative', 'preterite', 'singular', 'third-person'],
        ],
        entry: DictionaryEntry(
          lemma: 'aufheben',
          pos: 'verb',
          french: ['Ramasser.', 'Conserver.'],
        ),
      ),
      heben,
    ],
    'hob|Gregor hob den Kopf.': [heben],
    'Hauses|': [
      const WordAnalysis(
        lemma: 'Haus',
        pos: 'noun',
        tagSets: [
          ['genitive', 'singular'],
        ],
        entry: DictionaryEntry(
          lemma: 'Haus',
          pos: 'noun',
          gender: 'n',
          english: ['house'],
        ),
      ),
    ],
  };

  Future<(TranslationController, FakeDictionaries)> pumpPanel(
    WidgetTester tester, {
    bool installed = true,
    String source = 'de',
  }) async {
    final dictionaries = FakeDictionaries(
      installed: installed ? {'de'} : {},
      answers: answers,
    );
    final controller = TranslationController(
      model: FakeTranslationModel(),
      settings: ReaderSettings.memory(),
      source: source,
      dictionaries: dictionaries,
    );
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ReaderTheme.light.toThemeData(),
        home: Scaffold(
          body: SizedBox(
            width: TranslationPanel.width,
            child: TranslationPanel(controller: controller),
          ),
        ),
      ),
    );
    return (controller, dictionaries);
  }

  Finder selectable(String text) => find.byWidgetPredicate(
    (w) =>
        w is SelectableText &&
        (w.data ?? w.textSpan?.toPlainText() ?? '') == text,
  );

  testWidgets('a word shows its base form, grammar and definitions', (
    tester,
  ) async {
    final (controller, _) = await pumpPanel(tester);
    controller.translate('hob', context: sentence, sentence: sentence);
    await tester.pumpAndSettle();

    expect(find.text('hob … auf'), findsOneWidget);
    expect(selectable('aufheben  verbe'), findsOneWidget);
    expect(
      selectable('indicatif · prétérit · 3e pers. · sing.'),
      findsNWidgets(2),
    );
    expect(selectable('1. Ramasser.'), findsOneWidget);
    expect(selectable('2. Conserver.'), findsOneWidget);
    expect(selectable('heben  verbe'), findsOneWidget);
    expect(selectable('Soulever, élever.'), findsOneWidget);
    // The translation in context is still there.
    expect(find.text('In this sentence'), findsOneWidget);
    expect(selectable('[fr] hob'), findsOneWidget);
  });

  testWidgets('nouns have their article; English definitions as fallback', (
    tester,
  ) async {
    final (controller, _) = await pumpPanel(tester);
    controller.translate('Hauses');
    await tester.pumpAndSettle();
    expect(selectable('das Haus  nom, neutre'), findsOneWidget);
    expect(selectable('génitif · sing.'), findsOneWidget);
    expect(selectable('house'), findsOneWidget);
  });

  testWidgets('the dictionary is installed from the panel', (tester) async {
    final (controller, dictionaries) = await pumpPanel(
      tester,
      installed: false,
    );
    controller.translate('hob', sentence: 'Gregor hob den Kopf.');
    await tester.pumpAndSettle();
    expect(find.textContaining('About 1 MB is downloaded'), findsOneWidget);

    await tester.tap(find.text('Install the German dictionary'));
    await tester.pumpAndSettle();
    expect(dictionaries.installs, ['de']);
    expect(selectable('heben  verbe'), findsOneWidget);
  });

  testWidgets('a passage gets no word section; unknown words say so', (
    tester,
  ) async {
    final (controller, _) = await pumpPanel(tester);
    controller.translate(sentence);
    await tester.pumpAndSettle();
    expect(controller.word, isNull);
    expect(find.text('In this sentence'), findsNothing);

    controller.translate('Ungeziefer');
    await tester.pumpAndSettle();
    expect(find.text('“Ungeziefer” is not in the dictionary.'), findsOneWidget);
  });

  testWidgets('no word section for a language without dictionary', (
    tester,
  ) async {
    final (controller, _) = await pumpPanel(tester, source: 'fr');
    controller.translate('maman');
    await tester.pumpAndSettle();
    expect(controller.word, isNull);
    expect(find.text('In this sentence'), findsNothing);
  });
}
