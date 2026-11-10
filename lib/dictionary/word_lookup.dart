import 'dictionary_index.dart';

/// One way to read a word: an inflection of [lemma] ([pos]) with each of
/// [tagSets] (several when the form is ambiguous, e.g. dative masculine or
/// neuter), and the dictionary [entry] of the lemma when it has one.
class WordAnalysis {
  const WordAnalysis({
    required this.lemma,
    required this.pos,
    required this.tagSets,
    this.entry,
    this.note,
  });

  final String lemma;
  final String pos;
  final List<List<String>> tagSets;
  final DictionaryEntry? entry;

  /// How the word was matched when not directly, e.g. `hob … auf` for a
  /// separable verb or `dijeron + le` for a verb with a pronoun attached.
  final String? note;
}

/// Finds the analyses of a word of a book, using the sentence it is in.
abstract interface class WordLookup {
  /// Analyses of [word], most likely first; empty if it is unknown.
  Future<List<WordAnalysis>> lookUp(String word, {String? sentence});

  /// Most analyses returned.
  static const maxAnalyses = 6;

  /// [items] sorted by [key], keeping the order of items with equal keys.
  static List<T> mergeSort<T>(List<T> items, int Function(T) key) {
    final indexed = items.indexed.toList()
      ..sort((a, b) {
        final c = key(a.$2).compareTo(key(b.$2));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

  static bool _startsLower(String s) =>
      s.isNotEmpty && s[0] != s[0].toUpperCase();
  static bool _startsUpper(String s) =>
      s.isNotEmpty && s[0] != s[0].toLowerCase();

  /// [word] without the punctuation around it.
  static String cleanWord(String word) => word.trim().replaceAll(
    RegExp(r'^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$', unicode: true),
    '',
  );

  /// Whether [text] is a single word (what the word lookup is for).
  static bool isSingleWord(String text) {
    final clean = cleanWord(text);
    return clean.isNotEmpty &&
        clean.length <= 40 &&
        RegExp(
          r"^[\p{L}\p{M}]+(?:['’-][\p{L}\p{M}]+)*$",
          unicode: true,
        ).hasMatch(clean);
  }

  /// German particles that may belong to [word] as a separable verb: words
  /// of [sentence] after it that end a clause ("Er hob den Stein auf und…").
  static List<String> separableParticles(String word, String sentence) {
    final tokens = RegExp(
      r'[\p{L}\p{M}]+',
      unicode: true,
    ).allMatches(sentence).toList();
    final at = tokens.indexWhere((t) => t[0] == word);
    if (at < 0) return const [];
    final out = <String>[];
    for (var i = at + 1; i < tokens.length; i++) {
      final t = tokens[i][0]!;
      if (!_particles.contains(t)) continue;
      final next = i + 1 < tokens.length ? tokens[i + 1] : null;
      final between = sentence.substring(
        tokens[i].end,
        next?.start ?? sentence.length,
      );
      final endsClause =
          next == null ||
          RegExp(r'[,;:.!?…»«"“”()–—]').hasMatch(between) ||
          _conjunctions.contains(next[0]);
      if (endsClause && !out.contains(t)) out.add(t);
    }
    return out;
  }

  static const _particles = {
    'ab', 'an', 'auf', 'aus', 'bei', 'dabei', 'dar', 'davon', 'durch', //
    'ein', 'empor', 'entgegen', 'fest', 'fort', 'gegenüber', 'her', 'herab',
    'heran', 'herauf', 'heraus', 'herbei', 'herein', 'herüber', 'herum',
    'herunter', 'hervor', 'hin', 'hinab', 'hinauf', 'hinaus', 'hinein',
    'hinüber', 'hinunter', 'hinzu', 'los', 'mit', 'nach', 'nieder', 'statt',
    'teil', 'um', 'umher', 'unter', 'voran', 'voraus', 'vorbei', 'vorüber',
    'vor', 'weg', 'weiter', 'wieder', 'zu', 'zurecht', 'zurück', 'zusammen',
    'über',
  };

  static const _conjunctions = {'und', 'oder', 'aber', 'denn', 'sondern'};

  /// Ways to split a Spanish verb with attached pronouns ("dijéronle",
  /// "dámelo") into the verb and the pronouns, the verb also without the
  /// accent the pronouns added.
  static List<(String, String)> spanishCliticSplits(String word) {
    final lower = word.toLowerCase();
    final out = <(String, String)>[];
    final m = RegExp(
      r'^(.{2,}?)((?:me|te|se|nos|os|lo|la|los|las|le|les){1,3})$',
    ).firstMatch(lower);
    if (m == null) return out;
    var stem = m[1]!;
    var clitics = m[2]!;
    // Try the longest verb first: "dámelo" is "da" + "me" + "lo".
    while (true) {
      out.add((stem, _splitClitics(clitics)));
      final plain = _unaccent(stem);
      if (plain != stem) out.add((plain, _splitClitics(clitics)));
      final again = RegExp(r'^(me|te|se|nos|os|lo|la|los|las|le|les)(.+)$')
          .firstMatch(clitics);
      if (again == null) break;
      stem = '$stem${again[1]}';
      clitics = again[2]!;
    }
    return out.reversed.toList();
  }

  static String _splitClitics(String clitics) =>
      RegExp(r'nos|os|los|las|les|me|te|se|lo|la|le')
          .allMatches(clitics)
          .map((m) => m[0])
          .join(' + ');

  static String _unaccent(String s) => s
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u');

  static bool _sameTags(List<String> a, List<String> b) =>
      a.length == b.length && a.every(b.contains);
}

/// [WordLookup] in a dictionary index built from Wiktionary.
class IndexWordLookup implements WordLookup {
  IndexWordLookup(this.index, this.language);

  final DictionaryIndex index;
  final String language;

  /// Analyses of [word], most likely first; empty if it is unknown.
  @override
  Future<List<WordAnalysis>> lookUp(String word, {String? sentence}) async {
    final clean = WordLookup.cleanWord(word);
    if (clean.isEmpty) return const [];
    final found = <(FormMatch, String?)>[];

    if (language == 'de' && sentence != null) {
      for (final particle in WordLookup.separableParticles(clean, sentence)) {
        for (final m in await index.forms('$particle$clean')) {
          if (m.pos == 'verb') found.add((m, '$clean … $particle'));
        }
      }
    }
    var direct = await index.forms(clean);
    // A word written in lowercase is not a capitalized one (German nouns):
    // "alten" is not "Alten".
    if (WordLookup._startsLower(clean)) {
      direct = [
        for (final m in direct)
          if (!WordLookup._startsUpper(m.form)) m,
      ];
    }
    // Exact spelling first ("Essen" the noun before "essen"), then words
    // with French definitions.
    int rank(FormMatch m) => m.form == clean ? 0 : 1;
    found.addAll([
      for (final m in WordLookup.mergeSort(direct, rank)) (m, null),
    ]);

    if (direct.isEmpty && language == 'es') {
      for (final (stem, clitics) in WordLookup.spanishCliticSplits(clean)) {
        final matches = await index.forms(stem);
        for (final m in matches) {
          if (m.pos == 'verb') found.add((m, '$stem + $clitics'));
        }
        if (matches.any((m) => m.pos == 'verb')) break;
      }
    }

    // Group by lemma, keeping the order of first appearance.
    final groups = <String, (FormMatch, String?, List<List<String>>)>{};
    for (final (m, note) in found) {
      final key = '${m.lemma}\t${m.pos}\t${note ?? ''}';
      final g = groups.putIfAbsent(key, () => (m, note, <List<String>>[]));
      if (!g.$3.any((t) => WordLookup._sameTags(t, m.tags))) {
        g.$3.add(m.tags.where((t) => t != 'subordinate-clause').toList());
      }
    }
    final out = <WordAnalysis>[];
    for (final (m, note, tagSets) in groups.values) {
      if (out.length == WordLookup.maxAnalyses * 2) break;
      out.add(
        WordAnalysis(
          lemma: m.lemma,
          pos: m.pos,
          tagSets: [
            for (final t in tagSets)
              if (t.isNotEmpty || tagSets.length == 1) t,
          ],
          entry: await index.entry(m.lemma, m.pos),
          note: note,
        ),
      );
    }
    // Separable verbs first, then lemmas with French definitions.
    int order(WordAnalysis a) =>
        (a.note != null && language == 'de' ? 0 : 2) +
        ((a.entry?.french.isNotEmpty ?? false) ? 0 : 1);
    return WordLookup.mergeSort(
      out,
      order,
    ).take(WordLookup.maxAnalyses).toList();
  }
}
