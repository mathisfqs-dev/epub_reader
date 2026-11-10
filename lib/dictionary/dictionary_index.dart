import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A form of a word found in the dictionary: [form] is an inflection of
/// [lemma] ([pos]) with grammatical [tags] (wiktextract tags such as
/// `dative`, `third-person`; empty for the headword itself).
class FormMatch {
  const FormMatch(this.form, this.lemma, this.pos, this.tags);

  final String form;
  final String lemma;
  final String pos;
  final List<String> tags;

  @override
  String toString() => '$form → $lemma ($pos) ${tags.join(' ')}';
}

/// A dictionary headword: its gender (`m`, `f`, `n`, or several joined by
/// `/`) and definitions in French and English.
class DictionaryEntry {
  const DictionaryEntry({
    required this.lemma,
    required this.pos,
    this.gender,
    this.french = const [],
    this.english = const [],
  });

  final String lemma;
  final String pos;
  final String? gender;
  final List<String> french;
  final List<String> english;
}

/// Looks words up in an index written by `DictionaryBuilder`, reading only
/// a few kilobytes from disk per lookup.
class DictionaryIndex {
  DictionaryIndex._(this._forms, this._entries);

  static Future<DictionaryIndex> open(Directory directory) async =>
      DictionaryIndex._(
        await _SortedFile.open(directory, 'forms'),
        await _SortedFile.open(directory, 'entries'),
      );

  final _SortedFile _forms;
  final _SortedFile _entries;

  /// Every form whose lowercase spelling is [word]'s.
  Future<List<FormMatch>> forms(String word) async => [
    for (final f in await _forms.linesWithKey(word.toLowerCase()))
      if (f.length >= 5)
        FormMatch(f[1], f[2], f[3], f[4].isEmpty ? const [] : f[4].split(' ')),
  ];

  Future<DictionaryEntry?> entry(String lemma, String pos) async {
    for (final f in await _entries.linesWithKey(lemma)) {
      if (f.length < 5 || f[1] != pos) continue;
      List<String> split(String s) => s.isEmpty ? const [] : s.split(' | ');
      return DictionaryEntry(
        lemma: lemma,
        pos: pos,
        gender: f[2].isEmpty ? null : f[2],
        french: split(f[3]),
        english: split(f.length > 4 ? f[4] : ''),
      );
    }
    return null;
  }

  Future<void> close() async {
    await _forms.close();
    await _entries.close();
  }
}

/// A file of tab-separated lines sorted by their first field, with a sparse
/// index (`key, byte offset` every few lines) kept in memory.
class _SortedFile {
  _SortedFile(this._file, this._keys, this._offsets);

  static Future<_SortedFile> open(Directory directory, String name) async {
    final keys = <String>[];
    final offsets = <int>[];
    final lines = await File(p.join(directory.path, '$name.idx')).readAsLines();
    for (final line in lines) {
      final tab = line.lastIndexOf('\t');
      if (tab < 0) continue;
      keys.add(line.substring(0, tab));
      offsets.add(int.parse(line.substring(tab + 1)));
    }
    final file = await File(p.join(directory.path, '$name.tsv')).open();
    return _SortedFile(file, keys, offsets);
  }

  final RandomAccessFile _file;
  final List<String> _keys;
  final List<int> _offsets;

  /// Lookups share the file position: they run one at a time.
  Future<void> _last = Future.value();

  /// Fields of every line whose first field is [key].
  Future<List<List<String>>> linesWithKey(String key) {
    final result = _last.then((_) => _scan(key));
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<List<String>>> _scan(String key) async {
    // Start at the last indexed line whose key is before [key]: lines with
    // [key] may begin in the block before the first indexed one.
    var lo = 0;
    var hi = _keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_keys[mid].compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final start = lo == 0 ? 0 : _offsets[lo - 1];
    await _file.setPosition(start);
    final out = <List<String>>[];
    var pending = <int>[];
    while (true) {
      final chunk = await _file.read(16 * 1024);
      if (chunk.isEmpty) break;
      var lineStart = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        final bytes = pending.isEmpty
            ? chunk.sublist(lineStart, i)
            : [...pending, ...chunk.sublist(lineStart, i)];
        pending = <int>[];
        lineStart = i + 1;
        final line = utf8.decode(bytes, allowMalformed: true);
        final tab = line.indexOf('\t');
        final lineKey = tab < 0 ? line : line.substring(0, tab);
        final c = lineKey.compareTo(key);
        if (c > 0) return out;
        if (c == 0) out.add(line.split('\t'));
      }
      pending = [...pending, ...chunk.sublist(lineStart)];
    }
    return out;
  }

  Future<void> close() => _file.close();
}
