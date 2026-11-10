// Looks words up in a dictionary index built by build_dictionary.dart:
//
//   dart run tool/lookup_word.dart <index dir> <lang> "<word>|<sentence>"...
import 'dart:io';

import 'package:epub_reader/dictionary/dictionary_index.dart';
import 'package:epub_reader/dictionary/grammar_labels.dart';
import 'package:epub_reader/dictionary/word_lookup.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: lookup_word <index dir> <lang> "word|sentence"...');
    exit(64);
  }
  final index = await DictionaryIndex.open(Directory(args[0]));
  final lookup = IndexWordLookup(index, args[1]);
  for (final query in args.skip(2)) {
    final [word, ...rest] = query.split('|');
    final sentence = rest.isEmpty ? null : rest.join('|');
    final watch = Stopwatch()..start();
    final analyses = await lookup.lookUp(word, sentence: sentence);
    stdout.writeln('--- $word  (${watch.elapsedMilliseconds} ms)');
    for (final a in analyses) {
      final e = a.entry;
      final article = a.pos == 'noun'
          ? GrammarLabels.article(args[1], e?.gender)
          : null;
      stdout.writeln(
        '${a.note == null ? '' : '[${a.note}] '}'
        '${article == null ? '' : '$article '}${a.lemma}'
        ' (${GrammarLabels.pos(a.pos)}'
        '${e?.gender == null ? '' : ', ${GrammarLabels.gender(e!.gender!)}'})',
      );
      for (final line in GrammarLabels.describe(a.tagSets, pos: a.pos)) {
        stdout.writeln('    $line');
      }
      final defs = (e?.french.isNotEmpty ?? false) ? e!.french : e?.english;
      if (defs != null && defs.isNotEmpty) {
        stdout.writeln('    = ${defs.take(3).join(' ; ')}');
      }
    }
  }
  await index.close();
}
