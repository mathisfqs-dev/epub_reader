import 'dart:io';

import 'package:epub_reader/dictionary/dictionary_builder.dart';
import 'package:epub_reader/dictionary/dictionary_index.dart';
import 'package:epub_reader/dictionary/grammar_labels.dart';
import 'package:epub_reader/dictionary/word_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  late Directory german;
  late Directory spanish;
  late WordLookup de;
  late WordLookup es;

  setUpAll(() async {
    german = await buildIndex('de', germanInflections, germanDefinitions);
    spanish = await buildIndex('es', spanishInflections);
    de = IndexWordLookup(await DictionaryIndex.open(german), 'de');
    es = IndexWordLookup(await DictionaryIndex.open(spanish), 'es');
  });

  tearDownAll(() {
    german.deleteSync(recursive: true);
    spanish.deleteSync(recursive: true);
  });

  List<String> describe(WordAnalysis a) =>
      GrammarLabels.describe(a.tagSets, pos: a.pos);

  test('a verb form gives its infinitive, tense and person', () async {
    final [heben] = await de.lookUp('hob', sentence: 'Gregor hob den Kopf.');
    expect((heben.lemma, heben.pos, heben.note), ('heben', 'verb', null));
    // "past" (a summary line of the table) is left out.
    expect(describe(heben), ['indicatif · prétérit · 1re/3e pers. · sing.']);
    expect(heben.entry!.french, ['Soulever, élever.']);
    expect(heben.entry!.english, ['to lift']);
  });

  test('a separable verb is found with its particle', () async {
    final found = await de.lookUp(
      'hob',
      sentence: 'Er hob den Stein auf und warf ihn weg.',
    );
    expect(found.map((a) => a.lemma), ['aufheben', 'heben']);
    expect(found.first.note, 'hob … auf');
    expect(describe(found.first), ['indicatif · prétérit · 3e pers. · sing.']);
    // "auf den Tisch" is a preposition, not the end of the clause.
    final notSeparable = await de.lookUp(
      'hob',
      sentence: 'Er hob den Stein auf den Tisch.',
    );
    expect(notSeparable.map((a) => a.lemma), ['heben']);
  });

  test('ambiguous forms are merged on one line', () async {
    final [der] = await de.lookUp('dem');
    expect(der.lemma, 'der');
    expect(describe(der), ['datif · masc./neutre · sing. · défini']);
  });

  test('adjective forms given with their article are indexed', () async {
    // Lowercase "alten" is not the noun "Alten".
    final [alt] = await de.lookUp('alten');
    expect(alt.lemma, 'alt');
    expect(describe(alt), [
      'datif · masc. · sing. · décl. faible · après art. défini',
    ]);
  });

  test('nouns have their gender; punctuation around is ignored', () async {
    final [haus] = await de.lookUp('«Hauses,»');
    expect((haus.lemma, haus.entry!.gender), ('Haus', 'n'));
    expect(describe(haus), ['génitif · sing.']);
    expect(GrammarLabels.article('de', haus.entry!.gender), 'das');
    expect(haus.entry!.french, ['Maison.']);
  });

  test('"form of" entries point to their lemma', () async {
    final [heben] = await de.lookUp('gehoben');
    expect(heben.lemma, 'heben');
    expect(describe(heben), ['participe · passé']);
  });

  test('a Spanish verb with an attached pronoun', () async {
    final [decir] = await es.lookUp('Dijéronle');
    expect((decir.lemma, decir.note), ('decir', 'dijeron + le'));
    expect(describe(decir), ['indicatif · prétérit · 3e pers. · plur.']);
  });

  test('unknown words and other languages give nothing', () async {
    expect(await de.lookUp('Ungeziefer'), isEmpty);
    expect(await de.lookUp('house'), isEmpty);
    expect(await de.lookUp('...'), isEmpty);
  });

  test('isSingleWord', () {
    expect(WordLookup.isSingleWord(' hob, '), isTrue);
    expect(WordLookup.isSingleWord('Er hob'), isFalse);
    expect(WordLookup.isSingleWord("l'homme"), isTrue);
    expect(WordLookup.isSingleWord('1942'), isFalse);
  });

  test('the index finds keys across its blocks', () async {
    final builder = DictionaryBuilder('de');
    for (var i = 0; i < 1000; i++) {
      builder.addInflections({
        'word': 'wort${i.toString().padLeft(4, '0')}',
        'lang_code': 'de',
        'pos': 'noun',
        'senses': [
          {
            'glosses': ['word $i'],
          },
        ],
      });
    }
    final dir = Directory.systemTemp.createTempSync('dict_blocks');
    addTearDown(() => dir.deleteSync(recursive: true));
    await builder.write(dir);
    final index = await DictionaryIndex.open(dir);
    for (final i in [0, 1, 63, 64, 65, 500, 999]) {
      final word = 'wort${i.toString().padLeft(4, '0')}';
      final [match] = await index.forms(word);
      expect(match.lemma, word);
      expect((await index.entry(word, 'noun'))!.english, ['word $i']);
    }
    expect(await index.forms('wort1000'), isEmpty);
    expect(await index.forms('a'), isEmpty);
    await index.close();
  });
}
