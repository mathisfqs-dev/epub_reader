// Builds a dictionary index from local kaikki.org (wiktextract) files, the
// same way the app does after downloading them:
//
//   dart run tool/build_dictionary.dart <lang> <english.jsonl> <french.jsonl> <out dir>
import 'dart:convert';
import 'dart:io';

import 'package:epub_reader/dictionary/dictionary_builder.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'usage: build_dictionary <lang> <english.jsonl> <french.jsonl> <out dir>',
    );
    exit(64);
  }
  final [language, english, french, out] = args;
  final builder = DictionaryBuilder(language);
  final watch = Stopwatch()..start();
  Stream<String> lines(String path) =>
      File(path)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
  await builder.addLines(lines(english), builder.addInflections);
  stdout.writeln(
    'English Wiktionary: ${builder.formCount} forms, '
    '${builder.entryCount} entries (${watch.elapsed.inSeconds} s)',
  );
  await builder.addLines(lines(french), builder.addDefinitions);
  stdout.writeln(
    'French Wiktionary: ${builder.entryCount} entries '
    '(${watch.elapsed.inSeconds} s)',
  );
  await builder.write(Directory(out));
  stdout.writeln(
    'Written to $out (${watch.elapsed.inSeconds} s, '
    '${ProcessInfo.maxRss ~/ (1 << 20)} MB peak memory)',
  );
}
