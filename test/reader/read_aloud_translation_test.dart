import 'dart:io';

import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/epub/epub.dart';
import 'package:epub_reader/library/library_store.dart';
import 'package:epub_reader/reader/reader_screen.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/read_aloud_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../translate/fakes.dart';
import '../tts/fakes.dart';

void main() {
  late Book alice;
  late Directory installed;

  setUpAll(() async {
    alice = await const EpubParser().parseFile(
      'test/fixtures/books/alice_wonderland_images_epub3.epub',
    );
    installed = Directory.systemTemp.createTempSync('models');
    for (final f in KokoroModel(installed).files.required) {
      File(f).createSync(recursive: true);
    }
  });

  tearDownAll(() => installed.deleteSync(recursive: true));

  late FakeTranslator translator;

  Future<ReaderSettings> pumpReader(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = ReaderSettings.memory();
    translator = FakeTranslator();
    await tester.pumpWidget(
      MaterialApp(
        theme: ReaderTheme.light.toThemeData(),
        home: ReaderView(
          book: alice,
          settings: settings,
          initialPosition: const ReadingPosition(chapter: 1),
          voiceModel: KokoroModel(installed),
          translation: FakeTranslationModel(translator: translator),
          createReadAloud: (book) => ReadAloudController(
            book: book,
            synthesizer: () async => FakeSynthesizer(),
            output: FakeOutput(),
            voice: settings.voiceFor('en'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  ReaderViewState reader(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView));

  Future<void> chooseMode(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Translate while reading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('when paused: translates the sentence, kept while playing', (
    tester,
  ) async {
    final settings = await pumpReader(tester);
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();
    final controller = reader(tester).readAloud!;
    await tester.tap(find.byTooltip('Next sentence'));
    await tester.pumpAndSettle();
    final first = controller.textOf(controller.current!);

    // Off: pausing translates nothing.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(translator.requests, isEmpty);

    // Switching it on while paused translates right away, into French.
    await chooseMode(tester, 'When paused');
    expect(settings.readAloudTranslation, ReadAloudTranslateMode.onPause);
    expect(find.text('[fr] $first'), findsOneWidget);
    expect(translator.requests.single.context, isNotNull);
    // The side panel is not involved.
    expect(reader(tester).translation, isNull);

    // Playing on keeps it, even on the next sentences.
    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(find.text('[fr] $first'), findsOneWidget);
    await tester.tap(find.byTooltip('Next sentence'));
    await tester.pumpAndSettle();
    expect(find.text('[fr] $first'), findsOneWidget);
    expect(translator.requests, hasLength(1));

    // Pausing again translates the new sentence.
    final second = controller.textOf(controller.current!);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(find.text('[fr] $second'), findsOneWidget);

    // Another language, remembered apart from the side panel's.
    await tester.tap(find.byTooltip('Translate into'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch').last);
    await tester.pumpAndSettle();
    expect(find.text('[de] $second'), findsOneWidget);
    expect(settings.translationTarget('en', readAloud: true), 'de');
    expect(settings.translationTarget('en'), 'fr');

    // Off: hidden.
    await chooseMode(tester, 'Off');
    expect(find.text('[de] $second'), findsNothing);
  });

  testWidgets('every sentence: translates while playing, cancels if late', (
    tester,
  ) async {
    await pumpReader(tester);
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();
    final controller = reader(tester).readAloud!;
    await chooseMode(tester, 'Every sentence');
    expect(controller.isPlaying, isTrue);
    expect(
      find.text('[fr] ${controller.textOf(controller.current!)}'),
      findsOneWidget,
    );

    // Two sentences skipped faster than they are translated: the first
    // translation is cancelled, the last one shown.
    await tester.tap(find.byTooltip('Next sentence'));
    await tester.tap(find.byTooltip('Next sentence'));
    await tester.pumpAndSettle();
    expect(translator.cancelled, greaterThanOrEqualTo(1));
    expect(
      find.text('[fr] ${controller.textOf(controller.current!)}'),
      findsOneWidget,
    );
  });
}
