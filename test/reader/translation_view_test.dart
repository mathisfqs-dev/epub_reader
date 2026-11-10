import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/epub/epub.dart';
import 'package:epub_reader/library/library_store.dart';
import 'package:epub_reader/reader/block_view.dart';
import 'package:epub_reader/reader/reader_screen.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:epub_reader/translate/translation_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../translate/fakes.dart';

void main() {
  late Book alice;

  setUpAll(() async {
    alice = await const EpubParser().parseFile(
      'test/fixtures/books/alice_wonderland_images_epub3.epub',
    );
  });

  late FakeTranslator translator;

  Future<void> pumpReader(WidgetTester tester, {bool installed = true}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    translator = FakeTranslator();
    await tester.pumpWidget(
      MaterialApp(
        theme: ReaderTheme.light.toThemeData(),
        home: ReaderView(
          book: alice,
          settings: ReaderSettings.memory(),
          initialPosition: const ReadingPosition(chapter: 1),
          translation: FakeTranslationModel(
            installed: installed,
            translator: translator,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ReaderViewState reader(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView));

  testWidgets('selecting text offers to translate it, with its paragraph', (
    tester,
  ) async {
    await pumpReader(tester);
    final blocks = alice.chapters[1].blocks;
    final b = blocks.indexWhere(
      (x) => x.type == BlockType.paragraph && x.sentences.length >= 3,
    );
    final state = tester.state<BlockViewState>(
      find.byWidgetPredicate((w) => w is BlockView && w.block == blocks[b]),
    );
    final from = state.sentenceRect(1)!.center;
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(from + const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.byType(TranslationPanel), findsNothing);
    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();

    expect(find.byType(TranslationPanel), findsOneWidget);
    final request = translator.requests.single;
    expect(request.text, isNotEmpty);
    expect(blocks[b].text, contains(request.text));
    expect(request.context, blocks[b].text);
    expect((request.source, request.target), ('en', 'fr'));
    expect(find.text('[fr] ${request.text}'), findsOneWidget);

    await tester.tap(find.byTooltip('Close translation'));
    await tester.pumpAndSettle();
    expect(find.byType(TranslationPanel), findsNothing);
  });

  testWidgets('right-click > Translate sentence translates that sentence', (
    tester,
  ) async {
    await pumpReader(tester);
    final target = find.textContaining('Alice was beginning to get very tired');
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Translate sentence'));
    await tester.pumpAndSettle();

    final request = translator.requests.single;
    final block = alice.chapters[1].blocks.firstWhere(
      (x) => x.text.contains('Alice was beginning to get very tired'),
    );
    expect([
      for (var i = 0; i < block.sentences.length; i++) block.sentenceText(i),
    ], contains(request.text));
    expect(request.context, block.text);
  });

  testWidgets('changing the language in the panel translates again', (
    tester,
  ) async {
    await pumpReader(tester);
    reader(tester).translate('Alice sat down.');
    await tester.pumpAndSettle();
    expect(find.text('[fr] Alice sat down.'), findsOneWidget);

    await tester.tap(find.byTooltip('Translate into'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch').last);
    await tester.pumpAndSettle();
    expect(find.text('[de] Alice sat down.'), findsOneWidget);
  });

  testWidgets('offers to download the model when missing', (tester) async {
    await pumpReader(tester, installed: false);
    reader(tester).translate('Alice sat down.');
    await tester.pumpAndSettle();
    expect(translator.requests, isEmpty);

    await tester.tap(find.textContaining('Download the model'));
    await tester.pumpAndSettle();
    expect(find.text('[fr] Alice sat down.'), findsOneWidget);
  });

  testWidgets('auto-translate selection translates without clicking', (
    tester,
  ) async {
    await pumpReader(tester);
    final blocks = alice.chapters[1].blocks;
    final b = blocks.indexWhere(
      (x) => x.type == BlockType.paragraph && x.sentences.length >= 3,
    );
    final state = tester.state<BlockViewState>(
      find.byWidgetPredicate((w) => w is BlockView && w.block == blocks[b]),
    );

    Future<void> select(int sentence) async {
      final from = state.sentenceRect(sentence)!.center;
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(from + const Offset(80, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 10));
    }

    await select(0);
    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();
    expect(translator.requests, hasLength(1));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(reader(tester).widget.settings.autoTranslateSelection, isTrue);

    await select(1);
    await tester.pumpAndSettle();
    expect(translator.requests, hasLength(2));
    expect(blocks[b].text, contains(translator.requests.last.text));
    expect(find.text('[fr] ${translator.requests.last.text}'), findsOneWidget);
    // The bubble no longer offers "Translate".
    expect(find.text('Translate'), findsNothing);
  });
}
