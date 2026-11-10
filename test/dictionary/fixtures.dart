import 'dart:io';

import 'package:epub_reader/dictionary/dictionaries.dart';
import 'package:epub_reader/dictionary/dictionary_builder.dart';
import 'package:epub_reader/dictionary/word_lookup.dart';

/// A few entries shaped like kaikki.org's English Wiktionary extract.
const germanInflections = <Map<String, Object?>>[
  {
    'word': 'heben',
    'lang_code': 'de',
    'pos': 'verb',
    'senses': [
      {
        'glosses': ['to lift'],
      },
    ],
    'forms': [
      {
        'form': 'hob',
        'tags': ['past'],
      },
      {
        'form': 'hob',
        'tags': ['first-person', 'indicative', 'preterite', 'singular'],
      },
      {
        'form': 'hob',
        'tags': ['indicative', 'preterite', 'singular', 'third-person'],
      },
      {
        'form': 'de-conj',
        'tags': ['inflection-template'],
      },
      {
        'form': 'habe gehoben',
        'tags': ['perfect'],
      },
    ],
  },
  {
    'word': 'aufheben',
    'lang_code': 'de',
    'pos': 'verb',
    'senses': [
      {
        'glosses': ['to pick up'],
      },
    ],
    'forms': [
      {
        'form': 'aufhob',
        'tags': [
          'indicative',
          'preterite',
          'singular',
          'subordinate-clause',
          'third-person',
        ],
      },
    ],
  },
  {
    'word': 'der',
    'lang_code': 'de',
    'pos': 'article',
    'senses': [
      {
        'glosses': ['the'],
      },
    ],
    'forms': [
      {
        'form': 'dem',
        'tags': ['dative', 'definite', 'masculine', 'singular'],
      },
      {
        'form': 'dem',
        'tags': ['dative', 'definite', 'neuter', 'singular'],
      },
    ],
  },
  {
    'word': 'alt',
    'lang_code': 'de',
    'pos': 'adj',
    'senses': [
      {
        'glosses': ['old'],
      },
    ],
    'forms': [
      {
        'form': 'dem alten',
        'tags': [
          'dative',
          'definite',
          'includes-article',
          'masculine',
          'singular',
          'weak',
        ],
      },
    ],
  },
  {
    'word': 'Alter',
    'lang_code': 'de',
    'pos': 'noun',
    'head_templates': [
      {'expansion': 'Alter n (strong, genitive Alters)'},
    ],
    'senses': [
      {
        'glosses': ['age'],
      },
    ],
    'forms': [
      {
        'form': 'Alten',
        'tags': ['dative', 'plural'],
      },
    ],
  },
  {
    'word': 'Haus',
    'lang_code': 'de',
    'pos': 'noun',
    'senses': [
      {
        'glosses': ['house'],
        'tags': ['neuter', 'strong'],
      },
    ],
    'forms': [
      {
        'form': 'Hauses',
        'tags': ['genitive'],
      },
      {
        'form': 'Hauses',
        'tags': ['genitive', 'singular'],
      },
    ],
  },
  // A "form of" entry, and a word of another language.
  {
    'word': 'gehoben',
    'lang_code': 'de',
    'pos': 'verb',
    'senses': [
      {
        'glosses': ['past participle of heben'],
        'tags': ['form-of', 'participle', 'past'],
        'form_of': [
          {'word': 'heben'},
        ],
      },
    ],
  },
  {
    'word': 'house',
    'lang_code': 'en',
    'pos': 'noun',
    'senses': [
      {
        'glosses': ['Haus'],
      },
    ],
  },
];

/// Entries shaped like kaikki.org's French Wiktionary extract.
const germanDefinitions = <Map<String, Object?>>[
  {
    'word': 'heben',
    'lang_code': 'de',
    'pos': 'verb',
    'senses': [
      {
        'glosses': ['Soulever, élever.'],
      },
    ],
  },
  {
    'word': 'aufheben',
    'lang_code': 'de',
    'pos': 'verb',
    'senses': [
      {
        'glosses': ['Ramasser.'],
      },
    ],
  },
  {
    'word': 'Haus',
    'lang_code': 'de',
    'pos': 'noun',
    'tags': ['neuter'],
    'senses': [
      {
        'glosses': ['Maison.'],
      },
    ],
  },
  {
    'word': 'hob',
    'lang_code': 'de',
    'pos': 'verb',
    'tags': ['form-of'],
    'senses': [
      {
        'glosses': ['Prétérit de heben.'],
      },
    ],
  },
];

const spanishInflections = <Map<String, Object?>>[
  {
    'word': 'decir',
    'lang_code': 'es',
    'pos': 'verb',
    'senses': [
      {
        'glosses': ['to say'],
      },
    ],
    'forms': [
      {
        'form': 'dijeron',
        'tags': ['indicative', 'plural', 'preterite', 'third-person'],
      },
    ],
  },
];

/// Builds an index from [inflections] and [definitions] into a new
/// temporary folder.
Future<Directory> buildIndex(
  String language,
  List<Map<String, Object?>> inflections, [
  List<Map<String, Object?>> definitions = const [],
]) async {
  final builder = DictionaryBuilder(language);
  inflections.forEach(builder.addInflections);
  definitions.forEach(builder.addDefinitions);
  final dir = Directory.systemTemp.createTempSync('dict_$language');
  await builder.write(dir);
  return dir;
}

/// [Dictionaries] answering from [answers] (keyed `word|sentence`), with
/// no files: the index itself is tested in dictionary_test.dart.
class FakeDictionaries extends Dictionaries {
  FakeDictionaries({
    this.supported = const {'de'},
    Set<String>? installed,
    this.answers = const {},
  }) : installed = installed ?? {...supported};

  final Set<String> supported;
  final Set<String> installed;
  final Map<String, List<WordAnalysis>> answers;
  final installs = <String>[];

  @override
  DictionaryStatus status(String language) => !supported.contains(language)
      ? DictionaryStatus.unsupported
      : installed.contains(language)
      ? DictionaryStatus.ready
      : DictionaryStatus.missing;

  @override
  double? progress(String language) => null;
  @override
  String? error(String language) => null;
  @override
  String approximateSize(String language) => '1 MB';

  @override
  Future<void> install(String language) async {
    installs.add(language);
    installed.add(language);
    notifyListeners();
  }

  @override
  void cancel(String language) {}

  @override
  Future<WordLookup?> lookup(String language) async =>
      isReady(language) ? _CannedLookup(answers) : null;
}

class _CannedLookup implements WordLookup {
  _CannedLookup(this.answers);

  final Map<String, List<WordAnalysis>> answers;

  @override
  Future<List<WordAnalysis>> lookUp(String word, {String? sentence}) async =>
      answers['$word|${sentence ?? ''}'] ?? const [];
}
