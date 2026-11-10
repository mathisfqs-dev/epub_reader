import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Builds a dictionary index for one language from Wiktionary data
/// extracted by wiktextract (kaikki.org, one JSON object per line):
///
/// - [addInflections] takes entries of the English Wiktionary, which has
///   complete inflection tables (every form with its grammatical tags);
/// - [addDefinitions] takes entries of the French Wiktionary, for French
///   definitions of the same words.
///
/// [write] produces the files read by `DictionaryIndex`: `forms.tsv`
/// (`lowercase form, form, lemma, part of speech, tags`, sorted),
/// `entries.tsv` (`lemma, part of speech, gender, French definitions,
/// English definitions`, sorted) and a sparse index of each.
class DictionaryBuilder {
  DictionaryBuilder(this.language);

  /// Language code of the words (`de`, `es`…); other entries are skipped.
  final String language;

  // Build-time form lines carry a source rank before the tags: inflection
  // tables beat "form of" senses, which beat the bare headword.
  static const _fromTable = '0';
  static const _fromFormOf = '1';
  static const _fromHeadword = '2';

  final _forms = <String>{};
  final _entries = <String, _Entry>{};

  /// Parts of speech kept (proper nouns, symbols… are left out).
  static const keptPos = {
    'noun',
    'verb',
    'adj',
    'adv',
    'pron',
    'det',
    'article',
    'prep',
    'conj',
    'num',
    'particle',
    'intj',
    'contraction',
    'postp',
  };

  /// Form tags that only describe the table, not the form.
  static const _ignoredTags = {
    'table-tags',
    'inflection-template',
    'class',
    'canonical',
    'romanization',
    'multiword-construction',
    'includes-article',
    'form-of',
    'alt-of',
  };

  /// Adds one entry of the English Wiktionary extract.
  void addInflections(Map<String, Object?> entry) {
    if (entry['lang_code'] != language) return;
    final word = entry['word'];
    final pos = entry['pos'];
    if (word is! String || pos is! String || !keptPos.contains(pos)) return;
    if (word.contains(' ')) return;
    final senses = _list(entry['senses']);
    var isLemma = false;
    String? gender;
    final glosses = <String>[];
    for (final sense in senses.whereType<Map<String, Object?>>()) {
      final target =
          _list(sense['form_of']).firstOrNull ??
          _list(sense['alt_of']).firstOrNull;
      final tags = _tags(sense['tags']);
      if (target is Map && target['word'] is String) {
        final lemma = target['word'] as String;
        if (lemma.contains(' ')) continue;
        _addForm(word, lemma, pos, tags, _fromFormOf);
        continue;
      }
      isLemma = true;
      gender ??= _gender(tags);
      final gloss = _lastGloss(sense);
      if (gloss != null && glosses.length < 6 && !glosses.contains(gloss)) {
        glosses.add(gloss);
      }
    }
    if (!isLemma) return;
    final e = _entries.putIfAbsent('$word\t$pos', _Entry.new);
    e.gender ??= gender ?? _genderFromHead(entry);
    for (final g in glosses) {
      if (e.english.length < 6 && !e.english.contains(g)) e.english.add(g);
    }
    _addForm(word, word, pos, const [], _fromHeadword);
    for (final form in _list(
      entry['forms'],
    ).whereType<Map<String, Object?>>()) {
      final text = form['form'];
      final tags = _tags(form['tags']);
      if (text is! String || text.isEmpty || text == '-' || text == '—') {
        continue;
      }
      if (_list(form['tags']).any(_isTableOnly)) continue;
      var single = text;
      if (text.contains(' ')) {
        // German adjective tables give weak and mixed forms with their
        // article ("dem alten"): keep the adjective.
        if (!tags.contains('includes-article')) continue;
        single = text.split(' ').last;
      }
      _addForm(single, word, pos, tags, _fromTable);
    }
  }

  /// Adds one entry of the French Wiktionary extract.
  void addDefinitions(Map<String, Object?> entry) {
    if (entry['lang_code'] != language) return;
    final word = entry['word'];
    final pos = entry['pos'];
    if (word is! String || pos is! String || !keptPos.contains(pos)) return;
    final entryTags = _tags(entry['tags']);
    if (entryTags.contains('form-of') ||
        _list(entry['tags']).contains('form-of')) {
      return;
    }
    final glosses = <String>[];
    for (final sense in _list(
      entry['senses'],
    ).whereType<Map<String, Object?>>()) {
      if (_list(sense['tags']).contains('form-of')) continue;
      final gloss = _lastGloss(sense);
      if (gloss != null && glosses.length < 6 && !glosses.contains(gloss)) {
        glosses.add(gloss);
      }
    }
    if (glosses.isEmpty) return;
    final e = _entries.putIfAbsent('$word\t$pos', _Entry.new);
    e.gender ??= _gender(_list(entry['tags']).whereType<String>());
    for (final g in glosses) {
      if (e.french.length < 6 && !e.french.contains(g)) e.french.add(g);
    }
  }

  /// Adds every line of a JSON-lines stream with [add].
  Future<void> addLines(
    Stream<String> lines,
    void Function(Map<String, Object?>) add,
  ) async {
    await for (final line in lines) {
      if (line.isEmpty) continue;
      final Object? json;
      try {
        json = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (json is Map<String, Object?>) add(json);
    }
  }

  int get formCount => _forms.length;
  int get entryCount => _entries.length;

  /// Writes the index into [directory] (created if needed).
  Future<void> write(Directory directory) async {
    await directory.create(recursive: true);
    final forms = _forms.toList()..sort();
    _forms.clear();
    final kept = <String>[];
    // Lines of one (form, lemma, pos) are adjacent and sorted by source:
    // keep only those of the best source.
    String? group;
    String? best;
    for (final line in forms) {
      final cut = _nthTab(line, 4);
      final key = line.substring(0, cut);
      final source = line.substring(cut + 1, cut + 2);
      if (key != group) {
        group = key;
        best = source;
      }
      if (source != best) continue;
      kept.add('$key\t${line.substring(cut + 3)}');
    }
    await _writeSorted(directory, 'forms', kept);

    final entries = [
      for (final MapEntry(:key, :value) in _entries.entries)
        if (value.english.isNotEmpty || value.french.isNotEmpty)
          [
            key,
            value.gender ?? '',
            value.french.map(_clean).join(' | '),
            value.english.map(_clean).join(' | '),
          ].join('\t'),
    ]..sort();
    await _writeSorted(directory, 'entries', entries);
  }

  static Future<void> _writeSorted(
    Directory directory,
    String name,
    List<String> lines,
  ) async {
    final data = File(p.join(directory.path, '$name.tsv')).openWrite();
    final index = StringBuffer();
    var offset = 0;
    for (final (i, line) in lines.indexed) {
      if (i % indexEvery == 0) {
        index.write('${line.substring(0, line.indexOf('\t'))}\t$offset\n');
      }
      final bytes = utf8.encode('$line\n');
      data.add(bytes);
      offset += bytes.length;
    }
    await data.close();
    await File(p.join(directory.path, '$name.idx')).writeAsString('$index');
  }

  /// One key of the sparse index every this many lines.
  static const indexEvery = 64;

  void _addForm(
    String form,
    String lemma,
    String pos,
    List<String> tags,
    String source,
  ) {
    final clean = tags.where((t) => !_ignoredTags.contains(t)).toList()..sort();
    _forms.add(
      '${form.toLowerCase()}\t$form\t$lemma\t$pos\t$source\t${clean.join(' ')}',
    );
  }

  static bool _isTableOnly(Object? tag) =>
      tag == 'table-tags' ||
      tag == 'inflection-template' ||
      tag == 'auxiliary' ||
      tag == 'romanization' ||
      tag == 'class';

  static List<Object?> _list(Object? o) => o is List ? o : const [];

  static List<String> _tags(Object? o) => [
    for (final t in _list(o))
      if (t is String && !t.startsWith('error')) t,
  ];

  static String? _gender(Iterable<String> tags) {
    final g = [
      for (final t in const ['masculine', 'feminine', 'neuter'])
        if (tags.contains(t)) t[0],
    ];
    return g.isEmpty ? null : g.join('/');
  }

  /// Gender from a headword line such as "Haus n (strong, genitive…)".
  static String? _genderFromHead(Map<String, Object?> entry) {
    for (final h in _list(entry['head_templates'])) {
      final expansion = h is Map ? h['expansion'] : null;
      if (expansion is! String) continue;
      final m = RegExp(r'^\S+ ((?:[mfn](?:pl)?)(?: or [mfn])*)\b')
          .firstMatch(expansion);
      if (m != null) {
        return m.group(1)!.replaceAll(' or ', '/').replaceAll('pl', '');
      }
    }
    return null;
  }

  static String? _lastGloss(Map<String, Object?> sense) {
    final glosses = _list(sense['glosses']).whereType<String>();
    final g = glosses.lastOrNull?.trim();
    return g == null || g.isEmpty ? null : g;
  }

  static String _clean(String s) {
    final one = s.replaceAll(RegExp(r'[\t\n|]+'), ' ').trim();
    return one.length > 200 ? '${one.substring(0, 199)}…' : one;
  }

  static int _nthTab(String s, int n) {
    var i = -1;
    for (var k = 0; k < n; k++) {
      i = s.indexOf('\t', i + 1);
    }
    return i;
  }
}

class _Entry {
  String? gender;
  final english = <String>[];
  final french = <String>[];
}
