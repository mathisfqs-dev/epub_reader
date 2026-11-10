// Installs a dictionary for real, as the app does: downloads the Wiktionary
// extracts from kaikki.org (~130 MB for Spanish) and builds the index in a
// background isolate. Not part of the normal test run:
//
//   flutter test tool/dictionary_install_test.dart [--dart-define=LANG=de]
@Tags(['network'])
library;

import 'dart:io';

import 'package:epub_reader/dictionary/dictionaries.dart';
import 'package:flutter_test/flutter_test.dart';

const _language = String.fromEnvironment('LANG', defaultValue: 'es');

void main() {
  test('installs the $_language dictionary', () async {
    final dir = Directory.systemTemp.createTempSync('dictionaries');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dictionaries = WiktionaryDictionaries(dir);
    expect(dictionaries.status(_language), DictionaryStatus.missing);

    var last = -1.0;
    dictionaries.addListener(() {
      final p = dictionaries.progress(_language);
      if (p != null && p - last >= 0.1) {
        last = p;
        // ignore: avoid_print
        print('${(p * 100).toStringAsFixed(0)} %');
      }
    });
    final watch = Stopwatch()..start();
    await dictionaries.install(_language);
    // ignore: avoid_print
    print('Installed in ${watch.elapsed.inSeconds} s');

    expect(dictionaries.error(_language), isNull);
    expect(dictionaries.status(_language), DictionaryStatus.ready);
    final lookup = (await dictionaries.lookup(_language))!;
    final word = _language == 'de' ? 'hob' : 'dijeron';
    final [first, ...] = await lookup.lookUp(word);
    expect(first.lemma, _language == 'de' ? 'heben' : 'decir');
    expect(first.entry!.french, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
