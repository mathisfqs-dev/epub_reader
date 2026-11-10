import 'package:epub_reader/epub/epub.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> split(String text) {
  final spans = const SentenceSplitter().split(text);
  return [for (final s in spans) s.of(text)];
}

void main() {
  group('SentenceSplitter', () {
    test('splits simple sentences', () {
      expect(split('It rained. We stayed home! Did we? Yes…'), [
        'It rained.',
        'We stayed home!',
        'Did we?',
        'Yes…',
      ]);
    });

    test('keeps closing quotes with the sentence', () {
      expect(split('“Oh dear! Oh dear! I shall be late!” She ran.'), [
        '“Oh dear!',
        'Oh dear!',
        'I shall be late!”',
        'She ran.',
      ]);
    });

    test('does not split before lowercase continuation', () {
      expect(split('“Well!” thought Alice to herself.'), [
        '“Well!” thought Alice to herself.',
      ]);
      expect(split('I shall be late!” (when she thought it over) she ran.'), [
        'I shall be late!” (when she thought it over) she ran.',
      ]);
    });

    test('ignores abbreviations and initials', () {
      expect(split('Mr. Bennet and Mrs. Long met Dr. Jones. They talked.'), [
        'Mr. Bennet and Mrs. Long met Dr. Jones.',
        'They talked.',
      ]);
      expect(split('A letter from J. J. Rousseau arrived.'), [
        'A letter from J. J. Rousseau arrived.',
      ]);
      expect(split('Le Remercîment de Candide à M. de Voltaire est de 1760.'), [
        'Le Remercîment de Candide à M. de Voltaire est de 1760.',
      ]);
    });

    test('the pronoun I can end a sentence', () {
      expect(split('Nobody was happier than I. Then we left.'), [
        'Nobody was happier than I.',
        'Then we left.',
      ]);
    });

    test('ellipsis inside a sentence', () {
      expect(split('Well... perhaps not. Maybe.'), [
        'Well... perhaps not.',
        'Maybe.',
      ]);
    });

    test('French spacing before punctuation and guillemets', () {
      expect(split('« Quoi ! » dit-il. « Partons ! » Ils partirent.'), [
        '« Quoi ! » dit-il.',
        '« Partons ! »',
        'Ils partirent.',
      ]);
      expect(split('Hélas! dit Candide. Cunégonde est morte!'), [
        'Hélas! dit Candide.',
        'Cunégonde est morte!',
      ]);
    });

    test('verse: sentences run across line breaks', () {
      expect(
        split(
          'Shut not your doors to me proud libraries,\nFor I bring a book.',
        ),
        ['Shut not your doors to me proud libraries,\nFor I bring a book.'],
      );
    });

    test('text without terminator is one sentence, whitespace trimmed', () {
      expect(split('  CHAPTER I  '), ['CHAPTER I']);
      expect(split(''), isEmpty);
      expect(split('   '), isEmpty);
    });
  });
}
