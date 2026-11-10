import 'package:epub_reader/epub/epub.dart';
import 'package:flutter_test/flutter_test.dart';

const fixtures = 'test/fixtures/books';

const allBooks = [
  'alice_wonderland_images_epub3',
  'candide_fr_epub3',
  'leaves_of_grass_epub3',
  'pride_and_prejudice_epub2',
  'pride_and_prejudice_epub3',
];

Iterable<Block> allBlocks(Book book) => book.chapters.expand((c) => c.blocks);

Block blockContaining(Book book, String text) =>
    allBlocks(book).firstWhere((b) => b.text.contains(text));

void main() {
  final books = <String, Book>{};

  setUpAll(() async {
    for (final name in allBooks) {
      books[name] = await const EpubParser().parseFile('$fixtures/$name.epub');
    }
  });

  group('every test book', () {
    for (final name in allBooks) {
      group(name, () {
        late Book book;
        setUp(() => book = books[name]!);

        test('parses without warnings', () {
          expect(book.warnings, isEmpty);
          expect(book.chapters, isNotEmpty);
          expect(book.sentenceCount, greaterThan(500));
        });

        test('has a cover image', () {
          expect(book.metadata.coverImagePath, isNotNull);
          expect(book.resource(book.metadata.coverImagePath!), isNotNull);
        });

        test('table of contents is fully resolved', () {
          expect(book.toc, isNotEmpty);
          for (final entry in book.toc) {
            expect(
              entry.chapterIndex,
              inInclusiveRange(0, book.chapters.length - 1),
              reason: entry.title,
            );
            final chapter = book.chapters[entry.chapterIndex];
            expect(
              entry.blockIndex,
              inInclusiveRange(0, chapter.blocks.length - 1),
              reason: entry.title,
            );
          }
        });

        test('no Gutenberg boilerplate or page-number markers', () {
          for (final block in allBlocks(book)) {
            expect(block.text, isNot(contains('*** START OF')));
            expect(block.text, isNot(contains('*** END OF')));
            expect(block.text, isNot(contains('Project Gutenberg License')));
            expect(block.text, isNot(matches(RegExp(r'\{\d+\}'))));
          }
        });

        test('images exist in the archive', () {
          for (final block in allBlocks(
            book,
          ).where((b) => b.type == BlockType.image)) {
            expect(
              book.resource(block.imagePath!),
              isNotNull,
              reason: block.imagePath,
            );
          }
        });

        test('sentences cover every word of every block, in order', () {
          for (final block in allBlocks(book)) {
            if (block.type == BlockType.image ||
                block.type == BlockType.separator) {
              expect(block.sentences, isEmpty);
              continue;
            }
            expect(block.text.trim(), isNotEmpty);
            expect(block.sentences, isNotEmpty, reason: block.text);
            var previousEnd = 0;
            for (final s in block.sentences) {
              expect(s.start, greaterThanOrEqualTo(previousEnd));
              expect(s.end, greaterThan(s.start));
              expect(s.end, lessThanOrEqualTo(block.text.length));
              // Only whitespace between sentences.
              expect(
                block.text.substring(previousEnd, s.start).trim(),
                isEmpty,
                reason: block.text,
              );
              previousEnd = s.end;
            }
            expect(block.text.substring(previousEnd).trim(), isEmpty);
          }
        });

        test('inline runs concatenate to the block text', () {
          for (final block in allBlocks(book)) {
            expect(block.inlines.map((i) => i.text).join(), block.text);
          }
        });
      });
    }
  });

  group('Alice', () {
    late Book book;
    setUp(() => book = books['alice_wonderland_images_epub3']!);

    test('metadata', () {
      expect(book.metadata.title, "Alice's Adventures in Wonderland");
      expect(book.metadata.authors, ['Lewis Carroll']);
      expect(book.metadata.language, 'en');
    });

    test('chapters and TOC', () {
      expect(book.chapters, hasLength(13)); // title page + 12 chapters
      expect(book.chapters[1].title, 'CHAPTER I. Down the Rabbit-Hole');
      final entry = book.toc.firstWhere(
        (e) => e.title == 'CHAPTER XII. Alice’s Evidence',
      );
      expect(
        book.chapters[entry.chapterIndex].blocks[entry.blockIndex].text,
        'CHAPTER XII.\nAlice’s Evidence',
      );
    });

    test('first paragraph and italics', () {
      final chapter = book.chapters[1];
      expect(
        chapter.blocks[1].text,
        startsWith('Alice was beginning to get very tired'),
      );
      final block = blockContaining(
        book,
        'There was nothing so very remarkable',
      );
      expect(
        block.inlines.where((i) => i.italic).map((i) => i.text),
        contains('very'),
      );
    });

    test('poem keeps its lines and indentation', () {
      final poem = blockContaining(book, 'How doth the little crocodile');
      expect(poem.type, BlockType.verse);
      expect(poem.text.split('\n').take(2), [
        '“How doth the little crocodile',
        '    Improve his shining tail,',
      ]);
    });
  });

  group('Pride and Prejudice', () {
    late Book epub3;
    late Book epub2;
    setUp(() {
      epub3 = books['pride_and_prejudice_epub3']!;
      epub2 = books['pride_and_prejudice_epub2']!;
    });

    int chapterHeadings(Book b) => allBlocks(b)
        .where(
          (x) =>
              x.type == BlockType.heading &&
              RegExp(
                r'^chapter\s*[IVXLC]+',
                caseSensitive: false,
              ).hasMatch(x.text),
        )
        .length;

    test('all 61 chapter headings, in both versions', () {
      expect(chapterHeadings(epub3), 61);
      expect(chapterHeadings(epub2), 61);
    });

    test('EPUB2 and EPUB3 give the same text', () {
      expect(epub2.toc.map((e) => e.title), epub3.toc.map((e) => e.title));
      final ratio = epub2.sentenceCount / epub3.sentenceCount;
      expect(ratio, closeTo(1, 0.01));
    });

    test('TOC titles drop the illustration caption prefix', () {
      final titles = epub3.toc.map((e) => e.title).toList();
      expect(titles, contains('CHAPTER II.'));
      expect(titles.where((t) => t.contains('Bingley')), isEmpty);
    });

    test('illustrations only in the EPUB3 version', () {
      expect(
        allBlocks(epub3).where((b) => b.type == BlockType.image).length,
        106,
      );
      expect(allBlocks(epub2).where((b) => b.type == BlockType.image), isEmpty);
    });

    test('drop caps are folded into the text', () {
      for (final book in [epub3, epub2]) {
        expect(
          blockContaining(book, 'truth universally acknowledged').text,
          startsWith('IT is a truth universally acknowledged'),
        );
        expect(
          blockContaining(book, 'the ladies removed after dinner').text,
          startsWith('WHEN the ladies removed'),
        );
      }
    });

    test('caption inside a chapter heading is split out', () {
      final chapter = epub3.chapters.firstWhere(
        (c) => c.blocks.any((b) => b.text == 'Piling up the fire.'),
      );
      final i = chapter.blocks.indexWhere(
        (b) => b.text == 'Piling up the fire.',
      );
      expect(chapter.blocks[i - 1].type, BlockType.image);
      expect(chapter.blocks[i].type, BlockType.caption);
      expect(chapter.blocks[i + 1].type, BlockType.heading);
      expect(chapter.blocks[i + 1].text, 'CHAPTER XI.');
    });

    test('abbreviations do not split sentences', () {
      final block = blockContaining(
        epub3,
        'Mr. Hurst also made her a slight bow',
      );
      final sentences = [
        for (var i = 0; i < block.sentences.length; i++) block.sentenceText(i),
      ];
      expect(
        sentences,
        contains(startsWith('He addressed himself directly to Miss Bennet')),
      );
      expect(sentences.where((s) => s.endsWith('Mr.')), isEmpty);
    });
  });

  group('Leaves of Grass', () {
    late Book book;
    setUp(() => book = books['leaves_of_grass_epub3']!);

    test('one chapter per poem', () {
      expect(book.chapters, hasLength(377));
      expect(book.toc, hasLength(378));
    });

    test('pre poems are dedented', () {
      final chapter = book.chapters.firstWhere(
        (c) => c.title == 'Shut Not Your Doors',
      );
      final poem = chapter.blocks.firstWhere((b) => b.type == BlockType.verse);
      expect(poem.text.split('\n').take(3), [
        'Shut not your doors to me proud libraries,',
        'For that which was lacking on all your well-fill’d shelves, yet',
        '    needed most, I bring,',
      ]);
    });
  });

  group('Candide (French)', () {
    late Book book;
    setUp(() => book = books['candide_fr_epub3']!);

    test('metadata', () {
      expect(book.metadata.title, "Candide, ou l'optimisme");
      expect(book.metadata.authors, ['Voltaire']);
      expect(book.metadata.language, 'fr');
    });

    test('footnotes', () {
      expect(
        allBlocks(book).where((b) => b.type == BlockType.footnote).length,
        50,
      );
    });

    test('French sentences', () {
      final block = blockContaining(book, 'Candide effrayé recule.');
      final sentences = [
        for (var i = 0; i < block.sentences.length; i++) block.sentenceText(i),
      ];
      expect(
        sentences,
        containsAllInOrder([
          'Le fantôme le regarda fixement, versa des larmes, et sauta à son cou.',
          'Candide effrayé recule.',
          'Hélas! dit le misérable à l’autre misérable, ne reconnaissez-vous plus votre cher Pangloss?',
        ]),
      );
    });
  });
}
