// Prints the structure of an EPUB as parsed by lib/epub, to check the parser
// by eye.
//
// Usage:
//   dart run tool/dump_book.dart <file.epub> [--chapter N] [--blocks N] [--sentences]
//
//   (no options)   metadata, table of contents, chapter list
//   --chapter N    also print the blocks of chapter N
//   --blocks N     how many blocks to print (default 25, 0 = all)
//   --sentences    print each sentence of the printed blocks on its own line

import 'dart:io';

import 'package:epub_reader/epub/epub.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    stdout.writeln(
      'Usage: dart run tool/dump_book.dart <file.epub> '
      '[--chapter N] [--blocks N] [--sentences]',
    );
    exit(args.isEmpty ? 64 : 0);
  }

  final path = args.first;
  int? option(String name) {
    final i = args.indexOf(name);
    if (i < 0 || i + 1 >= args.length) return null;
    return int.tryParse(args[i + 1]);
  }

  final chapterIndex = option('--chapter');
  final maxBlocks = option('--blocks') ?? 25;
  final showSentences = args.contains('--sentences');

  final watch = Stopwatch()..start();
  final Book book;
  try {
    book = await const EpubParser().parseFile(path);
  } on EpubFormatException catch (e) {
    stderr.writeln(e);
    exit(1);
  }
  watch.stop();

  final m = book.metadata;
  stdout.writeln('══ ${m.title}');
  stdout.writeln('   authors:   ${m.authors.join(', ')}');
  stdout.writeln('   language:  ${m.language}');
  stdout.writeln('   id:        ${m.identifier}');
  final coverBytes = m.coverImagePath == null
      ? null
      : book.resource(m.coverImagePath!);
  stdout.writeln(
    '   cover:     ${m.coverImagePath} '
    '(${coverBytes == null ? 'missing' : '${coverBytes.length} bytes'})',
  );
  stdout.writeln(
    '   parsed in: ${watch.elapsedMilliseconds} ms — '
    '${book.chapters.length} chapters, ${book.sentenceCount} sentences',
  );
  if (book.warnings.isNotEmpty) {
    stdout.writeln('   warnings:');
    for (final w in book.warnings) {
      stdout.writeln('     ! $w');
    }
  }

  stdout.writeln('\n══ Table of contents (${book.toc.length} entries)');
  for (final e in book.toc) {
    final target = e.chapterIndex < 0
        ? 'UNRESOLVED'
        : 'ch ${e.chapterIndex} / block ${e.blockIndex}';
    stdout.writeln('   ${'  ' * e.depth}${e.title}  →  $target');
  }

  stdout.writeln('\n══ Chapters');
  for (var i = 0; i < book.chapters.length; i++) {
    final c = book.chapters[i];
    final types = <BlockType, int>{};
    for (final b in c.blocks) {
      types[b.type] = (types[b.type] ?? 0) + 1;
    }
    final summary = types.entries
        .map((e) => '${e.key.name} ${e.value}')
        .join(', ');
    stdout.writeln(
      '   [$i] ${c.title ?? '(untitled)'} — ${c.blocks.length} blocks, '
      '${c.sentenceCount} sentences ($summary)',
    );
  }

  if (chapterIndex == null) return;
  if (chapterIndex < 0 || chapterIndex >= book.chapters.length) {
    stderr.writeln('No chapter $chapterIndex');
    exit(1);
  }
  final chapter = book.chapters[chapterIndex];
  stdout.writeln(
    '\n══ Chapter $chapterIndex: ${chapter.title} (${chapter.path})',
  );
  final blocks = maxBlocks == 0
      ? chapter.blocks
      : chapter.blocks.take(maxBlocks).toList();
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final label = b.type == BlockType.heading ? 'h${b.level}' : b.type.name;
    if (b.type == BlockType.image) {
      final bytes = book.resource(b.imagePath!);
      stdout.writeln(
        '   #$i [image] ${b.imagePath} '
        '(${bytes == null ? 'MISSING' : '${bytes.length} bytes'})'
        '${b.imageAlt == null ? '' : ' alt="${b.imageAlt}"'}',
      );
      continue;
    }
    if (b.type == BlockType.separator) {
      stdout.writeln('   #$i [separator] ───');
      continue;
    }
    final styled = b.inlines
        .where((s) => s.italic || s.bold || s.smallCaps || s.href != null)
        .length;
    stdout.writeln(
      '   #$i [$label] ${b.sentences.length} sentence(s)'
      '${styled > 0 ? ', $styled styled run(s)' : ''}',
    );
    if (showSentences) {
      for (var s = 0; s < b.sentences.length; s++) {
        stdout.writeln('      ($s) ${_oneLine(b.sentenceText(s))}');
      }
    } else {
      for (final line in b.text.split('\n')) {
        stdout.writeln('      │ $line');
      }
    }
  }
  if (blocks.length < chapter.blocks.length) {
    stdout.writeln('   … ${chapter.blocks.length - blocks.length} more blocks');
  }
}

String _oneLine(String s) => s.replaceAll('\n', ' ⏎ ');
