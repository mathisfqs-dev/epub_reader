/// French labels for the grammatical tags of the dictionary (wiktextract
/// tags), merging the readings of an ambiguous form.
abstract final class GrammarLabels {
  static const _pos = {
    'noun': 'nom',
    'verb': 'verbe',
    'adj': 'adjectif',
    'adv': 'adverbe',
    'pron': 'pronom',
    'det': 'déterminant',
    'article': 'article',
    'prep': 'préposition',
    'postp': 'postposition',
    'conj': 'conjonction',
    'num': 'numéral',
    'particle': 'particule',
    'intj': 'interjection',
    'contraction': 'contraction',
  };

  /// Labels in display order; tags not listed are shown as they are.
  static const _tags = {
    // Verbs: mood and tense first.
    'infinitive': 'infinitif',
    'infinitive-zu': 'infinitif avec zu',
    'participle': 'participe',
    'gerund': 'gérondif',
    'indicative': 'indicatif',
    'subjunctive': 'subjonctif',
    'subjunctive-i': 'subjonctif I',
    'subjunctive-ii': 'subjonctif II',
    'conditional': 'conditionnel',
    'imperative': 'impératif',
    'affirmative': 'affirmatif',
    'negative': 'négatif',
    'present': 'présent',
    'preterite': 'prétérit',
    'past': 'passé',
    'imperfect': 'imparfait',
    'imperfect-se': 'en -se',
    'imperfect-ra': 'en -ra',
    'perfect': 'parfait',
    'pluperfect': 'plus-que-parfait',
    'future': 'futur',
    'future-i': 'futur I',
    'future-ii': 'futur II',
    'first-person': '1re',
    'second-person': '2e',
    'third-person': '3e',
    'formal': 'politesse',
    'informal': 'familier',
    // Nouns, articles, adjectives: case, gender, number.
    'nominative': 'nominatif',
    'accusative': 'accusatif',
    'dative': 'datif',
    'genitive': 'génitif',
    'masculine': 'masc.',
    'feminine': 'fém.',
    'neuter': 'neutre',
    'singular': 'sing.',
    'plural': 'plur.',
    'strong': 'décl. forte',
    'weak': 'décl. faible',
    'mixed': 'décl. mixte',
    'definite': 'défini',
    'indefinite': 'indéfini',
    'predicative': 'attribut',
    'positive': 'positif',
    'comparative': 'comparatif',
    'superlative': 'superlatif',
    'diminutive': 'diminutif',
    'augmentative': 'augmentatif',
    // Usage.
    'alternative': 'variante',
    'archaic': 'archaïque',
    'obsolete': 'vieilli',
    'dated': 'vieilli',
    'rare': 'rare',
    'colloquial': 'familier',
    'nonstandard': 'non standard',
    'regional': 'régional',
  };

  /// Tags not worth showing.
  static const _hidden = {
    'without-article',
    'with-article',
    'usually-without-article',
    'standard',
    'error-unrecognized-form',
  };

  static const _persons = ['first-person', 'second-person', 'third-person'];
  static const _genders = ['masculine', 'feminine', 'neuter'];
  static const _cases = ['nominative', 'accusative', 'dative', 'genitive'];
  static const _numbers = ['singular', 'plural'];

  static String pos(String pos) => _pos[pos] ?? pos;

  /// `m` → `masc.`, `m/n` → `masc./neutre`.
  static String gender(String gender) => gender
      .split('/')
      .map(
        (g) => switch (g) {
          'm' => 'masc.',
          'f' => 'fém.',
          'n' => 'neutre',
          _ => g,
        },
      )
      .join('/');

  /// Definite article of a noun of [gender] in [language], if it has one
  /// (`das` for a German neuter).
  static String? article(String language, String? gender) =>
      switch ((language, gender)) {
        ('de', 'm') => 'der',
        ('de', 'f') => 'die',
        ('de', 'n') => 'das',
        ('es', 'm') => 'el',
        ('es', 'f') => 'la',
        ('it', 'm') => 'il',
        ('it', 'f') => 'la',
        ('pt', 'm') => 'o',
        ('pt', 'f') => 'a',
        _ => null,
      };

  /// One line per distinct reading, readings differing only by person,
  /// gender, case or number merged: `prétérit · 1re/3e pers. sing.`.
  ///
  /// For an adjective ([pos] `adj`), `definite` means "after a definite
  /// article".
  static List<String> describe(List<List<String>> tagSets, {String? pos}) {
    var readings = [
      for (final tags in tagSets)
        {
          for (final t in tags)
            if (!_hidden.contains(t)) t,
        },
    ];
    for (final r in readings) {
      // "subjunctive-i" says "subjunctive" already.
      if (r.contains('subjunctive-i') || r.contains('subjunctive-ii')) {
        r.remove('subjunctive');
      }
      if (r.contains('future-i') || r.contains('future-ii')) {
        r.remove('future');
      }
      // German adjectives after "kein": the mixed declension says it.
      if (pos == 'adj') r.remove('negative');
    }
    // Summary lines of the tables repeat part of a full reading ("genitive"
    // next to "genitive singular"; "past" next to the preterite forms).
    final hasPreterite = readings.any((r) => r.contains('preterite'));
    readings = [
      for (final r in readings)
        if (!(hasPreterite && r.length == 1 && r.contains('past')) &&
            !readings.any((o) => o.length > r.length && o.containsAll(r)))
          r,
    ];
    for (final dimension in [_persons, _genders, _cases, _numbers]) {
      readings = _merge(readings, dimension);
    }
    final lines = <String>[];
    for (final r in readings) {
      var line = _format(r);
      if (pos == 'adj') {
        line = line
            .replaceAll(' · défini', ' · après art. défini')
            .replaceAll(' · indéfini', ' · après art. indéfini');
      }
      if (line.isNotEmpty && !lines.contains(line)) lines.add(line);
    }
    return lines;
  }

  /// Merges readings equal except for tags of [dimension]: they become one
  /// reading holding all those tags.
  static List<Set<String>> _merge(
    List<Set<String>> readings,
    List<String> dimension,
  ) {
    final groups = <String, Set<String>>{};
    for (final r in readings) {
      final rest = (r.where((t) => !dimension.contains(t)).toList()..sort())
          .join(' ');
      final values = r.where(dimension.contains);
      // A reading without this dimension is never merged with others.
      final key = values.isEmpty ? '$rest\u0000' : rest;
      groups.putIfAbsent(key, () => <String>{}).addAll(r);
    }
    return groups.values.toList();
  }

  static String _format(Set<String> reading) {
    final order = _tags.keys.toList();
    final known = reading.where(_tags.containsKey).toList()
      ..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    final other = reading.where((t) => !_tags.containsKey(t)).toList()..sort();
    final parts = <String>[];
    // Values of one dimension are joined with "/".
    List<String>? lastDimension;
    for (final t in known) {
      final dimension = [
        _persons,
        _genders,
        _cases,
        _numbers,
      ].where((d) => d.contains(t)).firstOrNull;
      final label = _tags[t]!;
      if (dimension != null && identical(dimension, lastDimension)) {
        parts[parts.length - 1] = '${parts.last}/$label';
      } else {
        parts.add(label);
      }
      lastDimension = dimension;
    }
    // "1re/3e" reads as persons only with "pers." after it.
    final persons = parts.indexWhere((p) => RegExp(r'^[123]').hasMatch(p));
    if (persons >= 0) parts[persons] = '${parts[persons]} pers.';
    return [...parts, ...other].join(' · ');
  }
}
