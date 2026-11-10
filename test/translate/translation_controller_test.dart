import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/translate/translation_controller.dart';
import 'package:epub_reader/translate/translator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test('streams the translation with the context', () async {
    final translator = FakeTranslator(pieces: ['Today, ', 'Mother died.']);
    final c = TranslationController(
      model: FakeTranslationModel(translator: translator),
      settings: ReaderSettings.memory(),
      source: 'fr',
    );
    final phases = <TranslationPhase>[];
    c.addListener(() => phases.add(c.phase));

    c.translate('  Aujourd’hui, maman est morte. ', context: 'Le paragraphe.');
    expect(c.isOpen, isTrue);
    await settle();

    expect(c.output, 'Today, Mother died.');
    expect(c.phase, TranslationPhase.done);
    expect(
      phases,
      containsAllInOrder([
        TranslationPhase.starting,
        TranslationPhase.streaming,
        TranslationPhase.done,
      ]),
    );
    final r = translator.requests.single;
    expect(r.text, 'Aujourd’hui, maman est morte.');
    expect((r.source, r.target, r.context), ('fr', 'en', 'Le paragraphe.'));
  });

  test('changing the target translates again and is remembered', () async {
    final settings = ReaderSettings.memory();
    final translator = FakeTranslator();
    final c = TranslationController(
      model: FakeTranslationModel(translator: translator),
      settings: settings,
      source: 'en',
    );
    c.translate('Hello.');
    await settle();
    expect(c.output, '[fr] Hello.');

    c.target = 'de';
    await settle();
    expect(c.output, '[de] Hello.');
    expect(settings.translationTarget('en'), 'de');
    expect(settings.translationTarget('fr'), 'en'); // other languages unchanged
  });

  test('a new request replaces the one in progress', () async {
    final translator = FakeTranslator();
    final c = TranslationController(
      model: FakeTranslationModel(translator: translator),
      settings: ReaderSettings.memory(),
      source: 'en',
    );
    c.translate('First.');
    await Future<void>.delayed(Duration.zero);
    c.translate('Second.');
    await settle();
    expect(c.output, '[fr] Second.');
    expect(c.request!.text, 'Second.');
  });

  test('waits for the model download, then translates', () async {
    final model = FakeTranslationModel(installed: false);
    final c = TranslationController(
      model: model,
      settings: ReaderSettings.memory(),
      source: 'en',
    );
    c.translate('Hello.');
    await settle();
    expect(c.phase, TranslationPhase.needsModel);

    await model.download();
    await settle();
    expect(c.phase, TranslationPhase.done);
    expect(c.output, '[fr] Hello.');
  });

  test('shows errors and keeps what was received', () async {
    final c = TranslationController(
      model: FakeTranslationModel(
        translator: FakeTranslator(
          pieces: ['Partial'],
          error: TranslationException('Server stopped'),
        ),
      ),
      settings: ReaderSettings.memory(),
      source: 'en',
    );
    c.translate('Hello.');
    await settle();
    expect(c.phase, TranslationPhase.failed);
    expect(c.error, 'Server stopped');
    expect(c.output, 'Partial');
  });

  test('long selections are cut and sent without context', () async {
    final translator = FakeTranslator();
    final c = TranslationController(
      model: FakeTranslationModel(translator: translator),
      settings: ReaderSettings.memory(),
      source: 'en',
    );
    c.translate('a' * (TranslationRequest.maxLength + 50), context: 'ctx');
    await settle();
    expect(c.truncated, isTrue);
    expect(
      translator.requests.single.text.length,
      TranslationRequest.maxLength,
    );
    expect(translator.requests.single.context, isNull);
  });

  test('closing stops the generation', () async {
    final translator = FakeTranslator(pieces: List.filled(50, 'x'));
    final c = TranslationController(
      model: FakeTranslationModel(translator: translator),
      settings: ReaderSettings.memory(),
      source: 'en',
    );
    c.translate('Hello.');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    c.close();
    await settle();
    expect(c.isOpen, isFalse);
    expect(c.output, '');
    expect(translator.cancelled, 1);
  });
}
