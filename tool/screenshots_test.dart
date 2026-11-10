// Renders screenshots of the app offscreen, with real fonts, for a visual
// check without a visible window.
//
//   flutter test tool/screenshots_test.dart --dart-define=OUT=/some/dir
//
// Writes PNGs to OUT (default: build/screenshots).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:epub_reader/app/app_scope.dart';
import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/dictionary/dictionary_index.dart';
import 'package:epub_reader/dictionary/word_lookup.dart';
import 'package:epub_reader/epub/epub.dart';
import 'package:epub_reader/library/library_screen.dart';
import 'package:epub_reader/library/library_store.dart';
import 'package:epub_reader/reader/block_view.dart';
import 'package:epub_reader/reader/reader_screen.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:epub_reader/translate/translation_controller.dart';
import 'package:epub_reader/translate/translation_model.dart';
import 'package:epub_reader/translate/translation_panel.dart';
import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/pocket_model.dart';
import 'package:epub_reader/tts/speech_models.dart';
import 'package:epub_reader/tts/voice.dart';
import 'package:epub_reader/tts/read_aloud_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../test/dictionary/fixtures.dart';
import '../test/translate/fakes.dart';
import '../test/tts/fakes.dart';

const _out = String.fromEnvironment('OUT', defaultValue: 'build/screenshots');
const _books = 'test/fixtures/books';

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    if (!File(f).existsSync()) continue;
    loader.addFont(
      Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
    );
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final material = [
    '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts',
  ].firstWhere((d) => Directory(d).existsSync());
  await _loadFont('Roboto', [
    for (final w in [
      'Regular',
      'Medium',
      'Bold',
      'Italic',
      'MediumItalic',
      'BoldItalic',
    ])
      '$material/Roboto-$w.ttf',
  ]);
  await _loadFont('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
  const sup = '/System/Library/Fonts/Supplemental';
  await _loadFont('Georgia', [
    '$sup/Georgia.ttf',
    '$sup/Georgia Bold.ttf',
    '$sup/Georgia Italic.ttf',
    '$sup/Georgia Bold Italic.ttf',
  ]);
  await _loadFont('Iowan Old Style', ['$sup/Iowan Old Style.ttc']);
}

void main() {
  late Directory dir;
  late LibraryStore library;
  final books = <String, Book>{};

  setUpAll(() async {
    await _loadFonts();
    Directory(_out).createSync(recursive: true);
    dir = Directory.systemTemp.createTempSync('shots');
    library = LibraryStore(dir);
    for (final name in [
      'alice_wonderland_images_epub3',
      'candide_fr_epub3',
      'leaves_of_grass_epub3',
      'pride_and_prejudice_epub3',
    ]) {
      await library.addBook('$_books/$name.epub');
      books[name] = await const EpubParser().parseFile('$_books/$name.epub');
    }
  });

  final boundary = GlobalKey();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await settle(tester);
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(_out, '$name.png'))
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<ReaderSettings> pumpApp(
    WidgetTester tester,
    Widget Function(ReaderSettings) home, {
    ReaderThemeMode mode = ReaderThemeMode.light,
    SpeechModels Function(ReaderSettings)? speech,
  }) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = ReaderSettings.memory()..themeMode = mode;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: AppScope(
          settings: settings,
          library: library,
          speech: speech?.call(settings),
          child: ListenableBuilder(
            listenable: settings,
            builder: (context, _) => MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ReaderTheme.forMode(
                settings.themeMode,
                Brightness.light,
              ).toThemeData(),
              home: home(settings),
            ),
          ),
        ),
      ),
    );
    return settings;
  }

  Widget reader(String book, ReaderSettings settings, ReadingPosition at) =>
      ReaderView(book: books[book]!, settings: settings, initialPosition: at);

  // The app's real models folder when it exists (read only): shows the
  // installed Pocket TTS languages.
  final appModels = Directory(
    p.join(
      Platform.environment['HOME'] ?? '',
      'Library/Application Support/com.example.epubReader/models',
    ),
  );

  testWidgets('library', (tester) async {
    await pumpApp(
      tester,
      (_) => const LibraryScreen(),
      speech: (s) => SpeechModels(
        settings: s,
        kokoro: KokoroModel(appModels),
        pocket: PocketModel(appModels),
      ),
    );
    await shoot(tester, '01_library_light');
    await tester.tap(find.byTooltip('Choose the read-aloud voice model'));
    await shoot(tester, '10_voice_model_picker');
    await tester.tap(find.text('Pocket TTS'));
    await shoot(tester, '11_voice_model_pocket');
    await tester.tap(find.text('Done'));
    await shoot(tester, '12_library_pocket');
  });

  testWidgets('selection bubble', (tester) async {
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books['alice_wonderland_images_epub3']!,
        settings: s,
        initialPosition: const ReadingPosition(chapter: 1),
        voiceModel: KokoroModel(appModels),
      ),
    );
    await settle(tester);
    final block = find.byType(BlockView).at(3);
    final state = tester.state<BlockViewState>(block);
    final from = state.sentenceRect(1)!.center;
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(from + const Offset(160, 34));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 10));
    await shoot(tester, '14_selection_bubble');
  });

  // Uses the real model through llama-server when installed.
  Future<void> translationShot(
    WidgetTester tester, {
    required String book,
    required ReadingPosition at,
    required int block,
    required int sentence,
    required ReaderThemeMode mode,
    required String name,
  }) async {
    final real = LlamaTranslationModel(appModels);
    final model = real.isReady ? real : FakeTranslationModel();
    addTearDown(() => tester.runAsync(real.unload));
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books[book]!,
        settings: s,
        initialPosition: at,
        voiceModel: KokoroModel(appModels),
        translation: model,
      ),
      mode: mode,
    );
    await settle(tester);
    final view = tester.state<ReaderViewState>(find.byType(ReaderView));
    final b = books[book]!.chapters[at.chapter].blocks[block];
    // Starts the server outside the test's fake clock, then what the reader
    // sends for a selection in that paragraph (the paragraph as context).
    await tester.runAsync(model.translator);
    view.translate(b.sentenceText(sentence));
    view.translation!.translate(b.sentenceText(sentence), context: b.text);
    for (var i = 0; i < 150 && view.translation!.isBusy; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print(
      '$name (${real.isReady ? 'real model' : 'fake'}): '
      '${view.translation!.phase} ${view.translation!.output}',
    );
    expect(view.translation!.phase, TranslationPhase.done);
    await shoot(tester, name);
  }

  testWidgets('translation panel (French book)', (tester) async {
    await translationShot(
      tester,
      book: 'candide_fr_epub3',
      at: const ReadingPosition(chapter: 7),
      block: 3,
      sentence: 1,
      mode: ReaderThemeMode.sepia,
      name: '15_translation_fr_en',
    );
  });

  testWidgets('translation panel (English book, dark)', (tester) async {
    await translationShot(
      tester,
      book: 'alice_wonderland_images_epub3',
      at: const ReadingPosition(chapter: 1),
      block: 3,
      sentence: 0,
      mode: ReaderThemeMode.dark,
      name: '16_translation_en_fr_dark',
    );
  });

  testWidgets('translation model download', (tester) async {
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books['alice_wonderland_images_epub3']!,
        settings: s,
        initialPosition: const ReadingPosition(chapter: 1),
        translation: FakeTranslationModel(installed: false),
      ),
    );
    await settle(tester);
    tester
        .state<ReaderViewState>(find.byType(ReaderView))
        .translate(
          'Alice was beginning to get very tired of sitting by her '
          'sister on the bank.',
        );
    await shoot(tester, '17_translation_download');
  });

  testWidgets('read aloud with Pocket TTS', (tester) async {
    final pocket = PocketModel(appModels);
    if (!pocket.isReady) return;
    final output = FakeOutput();
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books['candide_fr_epub3']!,
        settings: s..ttsModel = TtsModelKind.pocket,
        initialPosition: const ReadingPosition(chapter: 7),
        voiceModel: pocket,
        createReadAloud: (book) => ReadAloudController(
          book: book,
          synthesizer: () async => FakeSynthesizer(),
          output: output,
          voice: s.voiceIn(pocket, 'fr'),
        ),
      ),
    );
    await settle(tester);
    final view = tester.state<ReaderViewState>(find.byType(ReaderView));
    await tester.tap(find.byTooltip('Read aloud'));
    await settle(tester);
    view.readAloud!.startAt(const SentenceRef(7, 3, 1));
    await tester.tap(find.byTooltip('Voice'));
    await shoot(tester, '13_pocket_voice_menu');
  });

  testWidgets('reader light', (tester) async {
    await pumpApp(
      tester,
      (s) => reader(
        'alice_wonderland_images_epub3',
        s,
        const ReadingPosition(chapter: 2),
      ),
    );
    await shoot(tester, '02_reader_alice_light');
  });

  testWidgets('reader sepia with illustration', (tester) async {
    final pride = books['pride_and_prejudice_epub3']!;
    final c = pride.chapters.indexWhere(
      (c) => c.blocks.any((b) => b.text == 'Piling up the fire.'),
    );
    final b = pride.chapters[c].blocks.indexWhere(
      (b) => b.text == 'Piling up the fire.',
    );
    await pumpApp(
      tester,
      (s) => reader(
        'pride_and_prejudice_epub3',
        s,
        ReadingPosition(chapter: c, block: b - 1),
      ),
      mode: ReaderThemeMode.sepia,
    );
    await shoot(tester, '03_reader_pride_sepia');
  });

  testWidgets('reader dark poem + contents', (tester) async {
    final leaves = books['leaves_of_grass_epub3']!;
    final c = leaves.chapters.indexWhere(
      (c) => c.title == 'Shut Not Your Doors',
    );
    await pumpApp(
      tester,
      (s) => reader('leaves_of_grass_epub3', s, ReadingPosition(chapter: c)),
      mode: ReaderThemeMode.dark,
    );
    await shoot(tester, '04_reader_leaves_dark');
    await tester.tap(find.byTooltip('Contents'));
    await shoot(tester, '05_contents_dark');
  });

  testWidgets('appearance panel', (tester) async {
    await pumpApp(
      tester,
      (s) => reader('candide_fr_epub3', s, const ReadingPosition(chapter: 7)),
    );
    await tester.tap(find.byTooltip('Appearance'));
    await shoot(tester, '06_appearance_panel');
  });

  testWidgets('read aloud (dark, French)', (tester) async {
    final models = Directory.systemTemp.createTempSync('models');
    for (final f in KokoroModel(models).files.required) {
      File(f).createSync(recursive: true);
    }
    final output = FakeOutput();
    late ReaderViewState view;
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books['candide_fr_epub3']!,
        settings: s,
        initialPosition: const ReadingPosition(chapter: 7),
        voiceModel: KokoroModel(models),
        createReadAloud: (book) => ReadAloudController(
          book: book,
          synthesizer: () async => FakeSynthesizer(),
          output: output,
          voice: s.voiceFor('fr'),
        ),
      ),
      mode: ReaderThemeMode.dark,
    );
    await settle(tester);
    view = tester.state<ReaderViewState>(find.byType(ReaderView));
    await tester.tap(find.byTooltip('Read aloud'));
    await settle(tester);
    view.readAloud!.startAt(const SentenceRef(7, 3, 1));
    await shoot(tester, '07_read_aloud_dark');
    await tester.tap(find.byTooltip('Voice'));
    await shoot(tester, '08_voice_menu');
  });

  testWidgets('read aloud translated on pause', (tester) async {
    final models = Directory.systemTemp.createTempSync('models');
    for (final f in KokoroModel(models).files.required) {
      File(f).createSync(recursive: true);
    }
    late ReaderViewState view;
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books['pride_and_prejudice_epub3']!,
        settings: s..readAloudTranslation = ReadAloudTranslateMode.onPause,
        initialPosition: const ReadingPosition(chapter: 1),
        voiceModel: KokoroModel(models),
        translation: FakeTranslationModel(
          translator: FakeTranslator(
            pieces: [
              'C’est une vérité universellement reconnue qu’un célibataire ',
              'pourvu d’une belle fortune doit être en quête d’une épouse.',
            ],
          ),
        ),
        createReadAloud: (book) => ReadAloudController(
          book: book,
          synthesizer: () async => FakeSynthesizer(),
          output: FakeOutput(),
          voice: s.voiceFor('en'),
        ),
      ),
    );
    await settle(tester);
    view = tester.state<ReaderViewState>(find.byType(ReaderView));
    await tester.tap(find.byTooltip('Read aloud'));
    await settle(tester);
    view.readAloud!.startAt(const SentenceRef(1, 0, 0));
    await settle(tester);
    view.readAloud!.pause();
    await shoot(tester, '09_read_aloud_translated');
  });

  // Needs a German index built by tool/build_dictionary.dart:
  //   --dart-define=DE_DICTIONARY=<index dir>
  testWidgets('word lookup in the translation panel', (tester) async {
    const path = String.fromEnvironment('DE_DICTIONARY');
    if (path.isEmpty) return;
    const sentence = 'Er hob den Stein auf und warf ihn in den Fluss.';
    final answers = <String, List<WordAnalysis>>{};
    await tester.runAsync(() async {
      final lookup = IndexWordLookup(
        await DictionaryIndex.open(Directory(path)),
        'de',
      );
      answers['hob|$sentence'] = await lookup.lookUp('hob', sentence: sentence);
    });
    final controller = TranslationController(
      model: FakeTranslationModel(translator: FakeTranslator(pieces: ['leva'])),
      settings: ReaderSettings.memory(),
      source: 'de',
      dictionaries: FakeDictionaries(answers: answers),
    );
    addTearDown(controller.dispose);
    await pumpApp(
      tester,
      (s) => Scaffold(
        body: Row(
          children: [
            const Spacer(),
            SizedBox(
              width: TranslationPanel.width,
              child: TranslationPanel(controller: controller),
            ),
          ],
        ),
      ),
      mode: ReaderThemeMode.sepia,
    );
    controller.translate('hob', context: sentence, sentence: sentence);
    await shoot(tester, '16_word_lookup');
  });

  testWidgets('voice download dialog', (tester) async {
    final empty = Directory.systemTemp.createTempSync('nomodels');
    await pumpApp(
      tester,
      (s) => ReaderView(
        book: books['alice_wonderland_images_epub3']!,
        settings: s,
        initialPosition: const ReadingPosition(chapter: 1),
        voiceModel: KokoroModel(empty),
      ),
    );
    await tester.tap(find.byTooltip('Read aloud'));
    await shoot(tester, '09_voice_download');
  });
}
