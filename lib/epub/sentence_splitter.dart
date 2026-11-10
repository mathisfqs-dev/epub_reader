import 'model.dart';

/// Rule-based sentence splitter, good enough for read-aloud.
///
/// A sentence ends at `.`, `!`, `?` or `…` (plus any closing quotes or
/// brackets), when followed by whitespace and something that can start a
/// sentence: an uppercase letter, a digit or an opening quote/bracket/dash.
/// Common English and French abbreviations and single-letter initials don't
/// end a sentence. Handles French spacing (`Quoi ! » dit-il`).
class SentenceSplitter {
  const SentenceSplitter();

  static const _terminators = {'.', '!', '?', '…'};

  /// Closers that may directly follow a terminator: `."` `.)` `!’`.
  static const _closers = {'"', "'", '”', '’', '»', ')', ']', '›'};

  /// Closers that may be separated from the terminator by a space
  /// (French typography). Ambiguous straight quotes are excluded.
  static const _spacedClosers = {'»', '”', ')', ']', '›'};

  static const _openers = {
    '"',
    "'",
    '“',
    '‘',
    '«',
    '‹',
    '(',
    '[',
    '—',
    '–',
    '-',
    '¡',
    '¿',
    '_',
  };

  /// Words followed by a period that don't end a sentence.
  static const _abbreviations = {
    // English titles and common abbreviations.
    'Mr', 'Mrs', 'Ms', 'Messrs', 'Dr', 'St', 'Mt', 'Jr', 'Sr', 'Esq', 'Rev',
    'Hon', 'Prof', 'Capt', 'Col', 'Gen', 'Lt', 'Sgt', 'Maj', 'Gov', 'Sen',
    'Rep', 'vs', 'viz', 'cf', 'ch', 'Ch', 'vol', 'Vol', 'pp', 'fig', 'Fig',
    'i.e', 'e.g', 'a.m', 'p.m', 'A.M', 'P.M', 'ca',
    // French.
    'M', 'MM', 'Mme', 'Mmes', 'Mlle', 'Mlles', 'Mgr', 'Me', 'Ste',
    'chap', 'éd', 'p',
  };

  List<SentenceSpan> split(String text) {
    final spans = <SentenceSpan>[];
    final n = text.length;
    var start = _skipSpaces(text, 0);
    var i = start;
    while (i < n) {
      final c = text[i];
      if (!_terminators.contains(c)) {
        i++;
        continue;
      }
      // Swallow runs like `?!` or `...`.
      var j = i + 1;
      while (j < n && _terminators.contains(text[j])) {
        j++;
      }
      j = _skipClosers(text, j);
      final isBoundary =
          j == n ||
          (_isSpace(text[j]) && _startsSentence(text, _skipSpaces(text, j)));
      if (isBoundary && !(c == '.' && j == i + 1 && _isAbbreviation(text, i))) {
        if (j > start) spans.add(SentenceSpan(start, j));
        start = _skipSpaces(text, j);
        i = start;
      } else {
        i = j;
      }
    }
    if (start < n) {
      final end = _trimEnd(text, n);
      if (end > start) spans.add(SentenceSpan(start, end));
    }
    return spans;
  }

  int _skipClosers(String text, int j) {
    final n = text.length;
    while (true) {
      while (j < n && _closers.contains(text[j])) {
        j++;
      }
      // French: `! »` — closer after a space.
      var k = j;
      while (k < n && _isSpace(text[k]) && text[k] != '\n') {
        k++;
      }
      if (k > j && k < n && _spacedClosers.contains(text[k])) {
        j = k + 1;
        continue;
      }
      return j;
    }
  }

  bool _startsSentence(String text, int k) {
    if (k >= text.length) return true;
    var c = text[k];
    if (_openers.contains(c)) {
      // `late!” (when she…` — an opener followed by lowercase continues
      // the sentence.
      var m = k;
      while (m < text.length &&
          (_openers.contains(text[m]) || _isSpace(text[m]))) {
        m++;
      }
      if (m >= text.length) return true;
      c = text[m];
      return !_isLower(c);
    }
    if (_isDigit(c)) return true;
    return c.toUpperCase() == c && c.toLowerCase() != c;
  }

  static bool _isLower(String c) =>
      c.toLowerCase() == c && c.toUpperCase() != c;

  /// Whether the `.` at [dot] ends an abbreviation or an initial.
  bool _isAbbreviation(String text, int dot) {
    var s = dot;
    while (s > 0 && (_isLetter(text[s - 1]) || text[s - 1] == '.')) {
      s--;
    }
    final word = text.substring(s, dot);
    if (word.isEmpty) return false;
    if (_abbreviations.contains(word)) return true;
    // Initials: "J. J. Rousseau", "U.S.A." — but not the pronoun "I.".
    if (word.length == 1 && word != 'I' && word.toUpperCase() == word) {
      return true;
    }
    return word.contains('.') && word.length <= 6; // e.g. "U.S", "i.e"
  }

  static int _skipSpaces(String text, int i) {
    while (i < text.length && _isSpace(text[i])) {
      i++;
    }
    return i;
  }

  static int _trimEnd(String text, int end) {
    while (end > 0 && _isSpace(text[end - 1])) {
      end--;
    }
    return end;
  }

  static bool _isSpace(String c) =>
      c == ' ' ||
      c == '\n' ||
      c == '\t' ||
      c == '\r' ||
      c == ' ' ||
      c == ' ' ||
      c == ' ';

  static bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39;
  }

  static bool _isLetter(String c) => c.toUpperCase() != c.toLowerCase();
}
