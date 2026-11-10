import 'dart:io';

import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/epub/epub.dart';
import 'package:epub_reader/library/library_store.dart';
import 'package:epub_reader/reader/block_view.dart';
import 'package:epub_reader/reader/reader_screen.dart';
import 'package:epub_reader/reader/selection_bubble.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/kokoro_voices.dart';
import 'package:epub_reader/tts/read_aloud_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:path/path.dart' as p;

import '../tts/fakes.dart';

void main() {
  late Book alice;
  late Directory installed;
  late Directory empty;

  setUpAll(() async {
    alice = await const EpubParser().parseFile(
      'test/fixtures/books/alice_wonderland_images_epub3.epub',
    );
    // A "model" made of empty files is enough for KokoroModel.isReady.
    installed = Directory.systemTemp.createTempSync('models');
    final files = KokoroModel(installed).files;
    for (final f in files.required) {
      File(f).createSync(recursive: true);
    }
    empty = Directory.systemTemp.createTempSync('nomodels');
  });

  tearDownAll(() {
    installed.deleteSync(recursive: true);
    empty.deleteSync(recursive: true);
  });

  late FakeSynthesizer synth;
  late FakeOutput output;

  Future<ReaderSettings> pumpReader(
    WidgetTester tester, {
    ReadingPosition start = const ReadingPosition(chapter: 1),
    bool modelInstalled = true,
    Size size = const Size(1400, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    synth = FakeSynthesizer();
    output = FakeOutput();
    final settings = ReaderSettings.memory();
    await tester.pumpWidget(
      MaterialApp(
        theme: ReaderTheme.light.toThemeData(),
        home: ReaderView(
          book: alice,
          settings: settings,
          initialPosition: start,
          voiceModel: KokoroModel(modelInstalled ? installed : empty),
          createReadAloud: (book) => ReadAloudController(
            book: book,
            synthesizer: () async => synth,
            output: output,
            voice: settings.voiceFor('en'),
            speed: settings.speechSpeed,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  ReaderViewState reader(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView));

  /// Texts of the spans drawn with the highlight color.
  List<String> highlighted(WidgetTester tester) {
    final out = <String>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan &&
            span.style?.backgroundColor == ReaderTheme.light.highlight) {
          out.add(span.text ?? '');
        }
        return true;
      });
    }
    return out;
  }

  testWidgets('Read aloud starts at the top of the page and highlights', (
    tester,
  ) async {
    await pumpReader(tester);
    expect(find.byTooltip('Pause'), findsNothing);

    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();

    final controller = reader(tester).readAloud!;
    expect(controller.state, ReadAloudState.playing);
    expect(controller.current!.chapter, 1);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Next sentence'), findsOneWidget);
    expect(find.text('Heart · US'), findsOneWidget);
    expect(find.text('1.0×'), findsOneWidget);
    // The chapter heading is read first.
    expect(highlighted(tester).join(), contains('CHAPTER I'));

    await tester.tap(find.byTooltip('Next sentence'));
    await tester.pumpAndSettle();
    expect(controller.current!.block, greaterThan(0));
    expect(highlighted(tester).join(), isNot(contains('CHAPTER I')));

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(controller.state, ReadAloudState.paused);
    expect(find.byTooltip('Play'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop reading'));
    await tester.pumpAndSettle();
    expect(controller.isActive, isFalse);
    expect(find.byTooltip('Play'), findsNothing);
    expect(highlighted(tester), isEmpty);
  });

  testWidgets('selecting text offers to read aloud from there', (tester) async {
    await pumpReader(tester);
    final view = reader(tester);
    final blocks = alice.chapters[1].blocks;
    final b = blocks.indexWhere(
      (x) => x.type == BlockType.paragraph && x.sentences.length >= 3,
    );
    final finder = find.byWidgetPredicate(
      (w) => w is BlockView && w.block == blocks[b],
    );
    final state = tester.state<BlockViewState>(finder);
    final from = state.sentenceRect(1)!.center;
    final expected = state.sentenceAt(from)!;

    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(from + const Offset(120, 30));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Read aloud from here'), findsOneWidget);
    // Above the selection.
    expect(
      tester
          .getBottomLeft(
            find
                .descendant(
                  of: find.byType(SelectionBubble),
                  matching: find.byType(Material),
                )
                .first,
          )
          .dy,
      lessThanOrEqualTo(from.dy),
    );

    await tester.tap(find.text('Read aloud from here'));
    await tester.pumpAndSettle();
    expect(find.text('Read aloud from here'), findsNothing);
    expect(view.readAloud!.current, SentenceRef(1, b, expected));
    expect(view.readAloud!.state, ReadAloudState.playing);
  });

  testWidgets('a click without selection shows no bubble', (tester) async {
    await pumpReader(tester);
    final para = find.byType(BlockView).at(2);
    final gesture = await tester.startGesture(
      tester.getCenter(para),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byType(SelectionBubble), findsNothing);
  });

  testWidgets('keeps the sentence on screen inside a long paragraph', (
    tester,
  ) async {
    // Chapter 5, block 27: ten sentences, taller than this window.
    await pumpReader(
      tester,
      start: const ReadingPosition(chapter: 5, block: 27),
      size: const Size(900, 450),
    );
    final view = reader(tester);
    final block = alice.chapters[5].blocks[27];
    expect(block.sentences.length, 10);
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();
    view.readAloud!.startAt(const SentenceRef(5, 27, 0));
    await tester.pumpAndSettle();

    final list = tester.getRect(find.byType(ScrollablePositionedList));
    var scrolled = false;
    for (var i = 0; i < block.sentences.length; i++) {
      expect(view.readAloud!.current, SentenceRef(5, 27, i));
      final state = tester.state<BlockViewState>(
        find.byWidgetPredicate((w) => w is BlockView && w.block == block),
      );
      final rect = state.sentenceRect(i)!;
      expect(rect.top, greaterThanOrEqualTo(list.top), reason: 'sentence $i');
      expect(
        rect.top,
        lessThan(list.bottom - 20),
        reason: 'sentence $i starts on screen',
      );
      if (i > 0 && rect.top < list.top + list.height * 0.3) scrolled = true;
      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pumpAndSettle();
    }
    expect(scrolled, isTrue);
  });

  testWidgets('follows the reading into the next chapter', (tester) async {
    await pumpReader(tester);
    final view = reader(tester);
    final blocks = alice.chapters[1].blocks;
    // The last block with something to say (the very last one is "* * *"-like).
    final last = blocks.lastIndexWhere(
      (b) =>
          b.type == BlockType.paragraph &&
          ReadAloudController.speakableText(b.text).isNotEmpty,
    );
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();
    view.readAloud!.startAt(
      SentenceRef(1, last, blocks[last].sentences.length - 1),
    );
    await tester.pumpAndSettle();
    expect(view.position.block, greaterThan(last - 10));

    output.finish();
    await tester.pumpAndSettle();
    expect(view.chapterIndex, 2);
    expect(view.readAloud!.current!.chapter, 2);
    expect(highlighted(tester), isNotEmpty);
  });

  testWidgets('changing voice and speed is remembered', (tester) async {
    final settings = await pumpReader(tester);
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Heart · US'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bella · US').last);
    await tester.pumpAndSettle();
    expect(settings.voiceFor('en'), voiceNamed('af_bella'));
    expect(reader(tester).readAloud!.voice, voiceNamed('af_bella'));

    await tester.tap(find.text('1.0×'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.2×').last);
    await tester.pumpAndSettle();
    expect(settings.speechSpeed, 1.2);
    expect(synth.requests.last.$2, voiceNamed('af_bella'));
    expect(synth.requests.last.$3, 1.2);
  });

  testWidgets('right-click > Read aloud from here starts at that sentence', (
    tester,
  ) async {
    await pumpReader(tester);
    final target = find.textContaining('Alice was beginning to get very tired');
    final center = tester.getCenter(target);
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read aloud from here'));
    await tester.pumpAndSettle();

    final controller = reader(tester).readAloud!;
    final ref = controller.current!;
    final block = alice.chapters[1].blocks[ref.block];
    expect(block.text, contains('Alice was beginning to get very tired'));
    // The click was in the middle of the paragraph, not on its first
    // sentence necessarily, but on one of its sentences.
    expect(ref.sentence, lessThan(block.sentences.length));
    expect(highlighted(tester), isNotEmpty);
  });

  testWidgets('offers to download the model when missing', (tester) async {
    await pumpReader(tester, modelInstalled: false);
    await tester.tap(find.byTooltip('Read aloud'));
    await tester.pumpAndSettle();
    expect(find.textContaining('one-time download'), findsOneWidget);
    expect(find.text('Download (350 MB)'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(reader(tester).readAloud, isNull);
  });

  test('KokoroModel sees an installed model', () {
    expect(KokoroModel(installed).isReady, isTrue);
    expect(KokoroModel(empty).status, ModelStatus.missing);
    expect(
      KokoroModel(installed).files.model,
      p.join(installed.path, KokoroModel.name, 'model.onnx'),
    );
  });
}
