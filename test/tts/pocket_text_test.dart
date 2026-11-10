import 'package:epub_reader/tts/pocket_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The `text` rules of the packs made by pocket_tts_export.
  const french = PocketTextRules(
    removeSemicolons: true,
    replaceCharacters: {
      '"': '',
      '“': '',
      '”': '',
      '„': '',
      '«': '',
      '»': '',
      '’': "'",
      '‘': "'",
      ':': ',',
      '(': '',
      ')': '',
      '[': '',
      ']': '',
      '–': ',',
    },
  );
  const english = PocketTextRules(replaceCharacters: {'’': "'", '‘': "'"});
  const spanish = PocketTextRules(
    replaceCharacters: {'"': '', '«': '', '»': '', '¡': '', '¿': ''},
  );

  // Expected values come from pocket_tts_export/text_prep.py (upstream's
  // prepare_text_prompt).
  final cases = <(PocketTextRules, String, String, int)>[
    (
      french,
      "« Aujourd'hui, maman est morte ; ou peut-être hier », dit-il.",
      "Aujourd'hui, maman est morte , ou peut-être hier , dit-il.",
      1,
    ),
    (french, 'oui', 'Oui.', 3),
    (
      french,
      '"Vraiment ?", demanda-t-elle : (sans doute) –',
      'Vraiment ? demanda-t-elle , sans doute.',
      1,
    ),
    (french, 'Il partit,', 'Il partit.', 3),
    (english, 'hello there', 'Hello there.', 3),
    (
      english,
      '“Who are you?” said the Caterpillar',
      '“Who are you?” said the Caterpillar.',
      1,
    ),
    (english, '« »', '« ».', 3),
    (spanish, '¿Dónde está? ¡Aquí!', 'Dónde está? Aquí!', 3),
  ];

  for (final (rules, input, text, guess) in cases) {
    test('prepares "$input" like upstream', () {
      final prepared = preparePocketText(input, rules)!;
      expect(prepared.text, text);
      expect(prepared.framesAfterEosGuess, guess);
    });
  }

  test('nothing left to say gives null', () {
    expect(preparePocketText('  « »  ', french), isNull);
    expect(preparePocketText('', english), isNull);
  });

  test('short inputs can be padded', () {
    const rules = PocketTextRules(padWithSpacesForShortInputs: true);
    expect(preparePocketText('hi', rules)!.text, '        Hi.');
  });

  test('rules are read from pocket.json', () {
    final rules = PocketTextRules.fromJson({
      'remove_semicolons': true,
      'replace_characters': {'«': ''},
      'append_terminal_punctuation': false,
    });
    expect(rules.removeSemicolons, isTrue);
    expect(rules.replaceCharacters, {'«': ''});
    expect(rules.capitalizeFirstLetter, isTrue);
    expect(preparePocketText('a; b', rules)!.text, 'A, b');
  });
}
