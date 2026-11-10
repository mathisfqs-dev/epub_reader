import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/epub/epub.dart';
import 'package:epub_reader/library/library_store.dart';
import 'package:epub_reader/reader/reader_screen.dart';
import 'package:epub_reader/theme/reader_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Book alice;
  late Book pride;

  setUpAll(() async {
    alice = await const EpubParser().parseFile(
      'test/fixtures/books/alice_wonderland_images_epub3.epub',
    );
    pride = await const EpubParser().parseFile(
      'test/fixtures/books/pride_and_prejudice_epub3.epub',
    );
  });

  Future<(ReaderSettings, List<ReadingPosition>)> pumpReader(
    WidgetTester tester,
    Book book, {
    ReadingPosition start = const ReadingPosition(),
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = ReaderSettings.memory();
    final positions = <ReadingPosition>[];
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          theme: ReaderTheme.forMode(
            settings.themeMode,
            Brightness.light,
          ).toThemeData(),
          home: ReaderView(
            book: book,
            settings: settings,
            initialPosition: start,
            onPositionChanged: positions.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (settings, positions);
  }

  ReaderViewState reader(WidgetTester tester) =>
      tester.state<ReaderViewState>(find.byType(ReaderView));

  testWidgets('shows the chapter at the saved position', (tester) async {
    await pumpReader(tester, alice, start: const ReadingPosition(chapter: 1));
    expect(
      find.textContaining('Alice was beginning to get very tired'),
      findsOneWidget,
    );
    expect(
      find.text('CHAPTER I. Down the Rabbit-Hole'),
      findsOneWidget,
    ); // app bar
  });

  testWidgets('restores a position in the middle of a chapter', (tester) async {
    await pumpReader(
      tester,
      alice,
      start: const ReadingPosition(chapter: 1, block: 20),
    );
    expect(
      reader(tester).position,
      const ReadingPosition(chapter: 1, block: 20),
    );
    expect(
      find.textContaining('Alice was beginning to get very tired'),
      findsNothing,
    );
  });

  testWidgets('next / previous chapter buttons', (tester) async {
    final (_, positions) = await pumpReader(
      tester,
      alice,
      start: const ReadingPosition(chapter: 1),
    );
    await tester.tap(find.byTooltip('Next chapter'));
    await tester.pumpAndSettle();
    expect(reader(tester).chapterIndex, 2);
    expect(find.textContaining('Curiouser and curiouser!'), findsOneWidget);
    expect(positions.last, const ReadingPosition(chapter: 2));

    await tester.tap(find.byTooltip('Previous chapter'));
    await tester.pumpAndSettle();
    expect(reader(tester).chapterIndex, 1);
  });

  testWidgets('table of contents jumps to an entry', (tester) async {
    final (_, positions) = await pumpReader(tester, alice);
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('CHAPTER V. Advice from a Caterpillar'),
      ),
    );
    await tester.pumpAndSettle();
    expect(reader(tester).chapterIndex, 5);
    expect(positions.last.chapter, 5);
    expect(
      find.textContaining('The Caterpillar and Alice looked at each other'),
      findsOneWidget,
    );
  });

  testWidgets('internal links in the contents table work', (tester) async {
    await pumpReader(tester, alice);
    // Title page: the "CHAPTER III." link goes to chapter 3.
    await tester.tapOnText(find.textRange.ofSubstring('CHAPTER III.'));
    await tester.pumpAndSettle();
    expect(reader(tester).chapterIndex, 3);
    expect(
      find.textContaining('They were indeed a queer-looking party'),
      findsOneWidget,
    );
  });

  testWidgets('appearance panel changes theme and text size', (tester) async {
    final (settings, _) = await pumpReader(
      tester,
      alice,
      start: const ReadingPosition(chapter: 1),
    );
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sepia'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ReaderThemeMode.sepia);
    expect(
      Theme.of(tester.element(find.byType(ReaderView))).scaffoldBackgroundColor,
      ReaderTheme.sepia.background,
    );

    await tester.tap(find.byTooltip('Increase text size'));
    await tester.pumpAndSettle();
    expect(settings.fontSize, ReaderSettings.defaultFontSize + 1);

    await tester.tap(find.text('Sans'));
    await tester.pumpAndSettle();
    expect(settings.font, ReaderFont.sans);
  });

  testWidgets('renders illustrations and captions', (tester) async {
    final chapter = pride.chapters.indexWhere(
      (c) => c.blocks.any((b) => b.text == 'Piling up the fire.'),
    );
    final block = pride.chapters[chapter].blocks.indexWhere(
      (b) => b.text == 'Piling up the fire.',
    );
    await pumpReader(
      tester,
      pride,
      start: ReadingPosition(chapter: chapter, block: block - 1),
    );
    expect(find.byType(Image), findsWidgets);
    expect(find.text('Piling up the fire.'), findsOneWidget);
    // Heading + app bar subtitle (current chapter).
    expect(find.text('CHAPTER XI.'), findsNWidgets(2));
  });
}
