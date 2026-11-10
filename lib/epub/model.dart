/// Book model produced by the EPUB parser.
///
/// Pure Dart (no Flutter imports) so it can be unit-tested and built in a
/// background isolate.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A parsed EPUB book.
class Book {
  Book({
    required this.metadata,
    required this.toc,
    required this.chapters,
    required this._archive,
    this.sourcePath,
    this.warnings = const [],
  });

  final BookMetadata metadata;

  /// Flat table of contents, in reading order. Nesting is given by
  /// [TocEntry.depth].
  final List<TocEntry> toc;

  /// Spine documents in reading order (cover page and empty documents are
  /// dropped). One chapter is one XHTML file of the EPUB: it may hold several
  /// logical chapters (Pride and Prejudice) or a single poem (Leaves of Grass).
  /// Use [toc] for navigation.
  final List<Chapter> chapters;

  /// File the book was loaded from, if any.
  final String? sourcePath;

  /// Non-fatal problems found while parsing (unreadable document, TOC entry
  /// pointing nowhere…).
  final List<String> warnings;

  final Archive _archive;

  /// Raw bytes of a file inside the EPUB, e.g. an image from
  /// [Block.imagePath] or [BookMetadata.coverImagePath].
  Uint8List? resource(String path) {
    final file = _archive.findFile(path);
    if (file == null || !file.isFile) return null;
    return file.content;
  }

  int get sentenceCount => chapters.fold(0, (sum, c) => sum + c.sentenceCount);
}

class BookMetadata {
  const BookMetadata({
    required this.title,
    required this.authors,
    this.language,
    this.identifier,
    this.coverImagePath,
  });

  final String title;
  final List<String> authors;

  /// BCP 47 language tag from `dc:language`, e.g. `en`, `fr`.
  final String? language;
  final String? identifier;

  /// Archive path of the cover image, readable with [Book.resource].
  final String? coverImagePath;
}

class TocEntry {
  TocEntry({
    required this.title,
    required this.depth,
    required this.path,
    this.fragment,
  });

  final String title;

  /// 0 for top-level entries.
  final int depth;

  /// Archive path of the target document.
  final String path;

  /// Anchor id inside the target document, if any.
  final String? fragment;

  /// Resolved target, set once chapters are built. -1 if the target could
  /// not be found.
  int chapterIndex = -1;
  int blockIndex = 0;
}

class Chapter {
  Chapter({
    required this.path,
    required this.blocks,
    required this.anchors,
    this.title,
  });

  /// Archive path of the source XHTML file.
  final String path;

  /// From the table of contents, else the first heading, else null.
  String? title;

  final List<Block> blocks;

  /// Element ids found in the document, mapped to the index of the block
  /// they belong to. Used to resolve TOC fragments and internal links.
  final Map<String, int> anchors;

  int get sentenceCount => blocks.fold(0, (sum, b) => sum + b.sentences.length);
}

enum BlockType {
  heading,
  paragraph,

  /// Block quotation, letter, epigraph…
  quote,

  /// Poetry or preformatted text: line breaks and indentation are meaningful.
  verse,

  /// Caption of an illustration.
  caption,
  footnote,
  image,

  /// Horizontal rule / scene break.
  separator,
}

class Block {
  Block({
    required this.type,
    required this.inlines,
    required this.sentences,
    this.level = 0,
    this.imagePath,
    this.imageAlt,
  }) : text = inlines.map((i) => i.text).join();

  final BlockType type;

  /// Heading level 1–6, 0 for other blocks.
  final int level;

  /// Styled runs. Their concatenation is [text].
  final List<Inline> inlines;

  /// Plain text of the block. Line breaks are `\n`.
  final String text;

  /// Sentence ranges inside [text] (end exclusive).
  final List<SentenceSpan> sentences;

  /// For [BlockType.image]: archive path of the image.
  final String? imagePath;
  final String? imageAlt;

  String sentenceText(int index) => sentences[index].of(text);
}

/// A run of text with a uniform style.
class Inline {
  const Inline(
    this.text, {
    this.italic = false,
    this.bold = false,
    this.smallCaps = false,
    this.superscript = false,
    this.href,
  });

  final String text;
  final bool italic;
  final bool bold;
  final bool smallCaps;
  final bool superscript;

  /// Link target, resolved to an archive path (`path#fragment`) for internal
  /// links, kept as-is for external ones.
  final String? href;

  bool sameStyle(Inline other) =>
      italic == other.italic &&
      bold == other.bold &&
      smallCaps == other.smallCaps &&
      superscript == other.superscript &&
      href == other.href;

  Inline withText(String newText) => Inline(
    newText,
    italic: italic,
    bold: bold,
    smallCaps: smallCaps,
    superscript: superscript,
    href: href,
  );

  @override
  String toString() => text;
}

/// A sentence as a character range of a block's text.
class SentenceSpan {
  const SentenceSpan(this.start, this.end);

  final int start;

  /// Exclusive.
  final int end;

  String of(String text) => text.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is SentenceSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SentenceSpan($start, $end)';
}

class EpubFormatException implements Exception {
  EpubFormatException(this.message);
  final String message;

  @override
  String toString() => 'EpubFormatException: $message';
}
