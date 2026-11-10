import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../epub/epub.dart';

/// Where the reader was in a book.
@immutable
class ReadingPosition {
  const ReadingPosition({this.chapter = 0, this.block = 0});

  final int chapter;
  final int block;

  factory ReadingPosition.fromJson(Map<String, dynamic> json) =>
      ReadingPosition(
        chapter: json['chapter'] as int? ?? 0,
        block: json['block'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {'chapter': chapter, 'block': block};

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      other.chapter == chapter &&
      other.block == block;

  @override
  int get hashCode => Object.hash(chapter, block);
}

/// A book linked into the library. The EPUB stays where it is; only its
/// path is stored.
class LibraryEntry {
  LibraryEntry({
    required this.id,
    required this.path,
    required this.title,
    required this.authors,
    required this.chapterCount,
    required this.addedAt,
    this.language,
    this.coverFile,
    this.position = const ReadingPosition(),
    this.lastOpenedAt,
  });

  final String id;
  String path;
  String title;
  List<String> authors;
  String? language;
  int chapterCount;

  /// Cached copy of the cover image, in the app's support folder.
  String? coverFile;
  ReadingPosition position;
  final DateTime addedAt;
  DateTime? lastOpenedAt;

  bool get fileExists => File(path).existsSync();

  String get authorLine => authors.join(', ');

  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    id: json['id'] as String,
    path: json['path'] as String,
    title: json['title'] as String,
    authors: (json['authors'] as List? ?? const []).cast<String>(),
    language: json['language'] as String?,
    chapterCount: json['chapterCount'] as int? ?? 0,
    coverFile: json['coverFile'] as String?,
    position: json['position'] is Map<String, dynamic>
        ? ReadingPosition.fromJson(json['position'] as Map<String, dynamic>)
        : const ReadingPosition(),
    addedAt: DateTime.parse(json['addedAt'] as String),
    lastOpenedAt: json['lastOpenedAt'] == null
        ? null
        : DateTime.parse(json['lastOpenedAt'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'title': title,
    'authors': authors,
    'language': language,
    'chapterCount': chapterCount,
    'coverFile': coverFile,
    'position': position.toJson(),
    'addedAt': addedAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt?.toIso8601String(),
  };
}

/// What [LibraryStore.addBook] did.
enum AddResult { added, alreadyInLibrary }

/// Metadata extracted in a background isolate when a book is added.
class _BookSummary {
  _BookSummary(this.metadata, this.chapterCount, this.cover);
  final BookMetadata metadata;
  final int chapterCount;
  final Uint8List? cover;
}

Future<_BookSummary> _summarize(String path) => Isolate.run(() async {
  final book = await const EpubParser().parseFile(path);
  final coverPath = book.metadata.coverImagePath;
  return _BookSummary(
    book.metadata,
    book.chapters.length,
    coverPath == null ? null : book.resource(coverPath),
  );
});

/// The list of linked books, saved as `library.json` in [directory].
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.directory);

  /// Opens the store in the app's Application Support folder.
  static Future<LibraryStore> open() async {
    final dir = await getApplicationSupportDirectory();
    final store = LibraryStore(dir);
    await store.load();
    return store;
  }

  final Directory directory;
  final List<LibraryEntry> _entries = [];
  Timer? _saveTimer;

  File get _file => File(p.join(directory.path, 'library.json'));
  Directory get _coversDir => Directory(p.join(directory.path, 'covers'));

  /// Most recently opened (or added) first.
  List<LibraryEntry> get entries {
    final list = [..._entries];
    list.sort(
      (a, b) =>
          (b.lastOpenedAt ?? b.addedAt).compareTo(a.lastOpenedAt ?? a.addedAt),
    );
    return List.unmodifiable(list);
  }

  LibraryEntry? byId(String id) =>
      _entries.where((e) => e.id == id).firstOrNull;

  Future<void> load() async {
    _entries.clear();
    if (await _file.exists()) {
      try {
        final json =
            jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        for (final item in json['books'] as List? ?? const []) {
          _entries.add(LibraryEntry.fromJson(item as Map<String, dynamic>));
        }
      } on FormatException catch (e) {
        debugPrint('library.json unreadable, starting empty: $e');
      }
    }
    notifyListeners();
    // Covers of books removed in an earlier session (kept until now so
    // "Undo" can restore them).
    await _deleteOrphanCovers();
  }

  /// Parses the EPUB at [path] and links it. Throws [EpubFormatException]
  /// if it can't be read.
  Future<AddResult> addBook(String path) async {
    final absolute = p.absolute(path);
    if (_entries.any((e) => e.path == absolute)) {
      return AddResult.alreadyInLibrary;
    }

    final summary = await _summarize(absolute);
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _entries.add(
      LibraryEntry(
        id: id,
        path: absolute,
        title: summary.metadata.title,
        authors: summary.metadata.authors,
        language: summary.metadata.language,
        chapterCount: summary.chapterCount,
        coverFile: await _writeCover(id, summary),
        addedAt: DateTime.now(),
      ),
    );
    notifyListeners();
    await save();
    return AddResult.added;
  }

  /// Points an entry at a new file (moved or renamed book).
  Future<void> relink(String id, String newPath) async {
    final entry = byId(id);
    if (entry == null) return;
    final summary = await _summarize(newPath);
    entry
      ..path = p.absolute(newPath)
      ..title = summary.metadata.title
      ..authors = summary.metadata.authors
      ..language = summary.metadata.language
      ..chapterCount = summary.chapterCount
      ..coverFile = await _writeCover(id, summary) ?? entry.coverFile;
    if (entry.position.chapter >= summary.chapterCount) {
      entry.position = const ReadingPosition();
    }
    notifyListeners();
    await save();
  }

  /// Removes the entry (the EPUB file itself is never touched). Returns it
  /// so it can be restored with [restore].
  LibraryEntry? remove(String id) {
    final entry = byId(id);
    if (entry == null) return null;
    _entries.remove(entry);
    notifyListeners();
    unawaited(save());
    return entry;
  }

  Future<void> restore(LibraryEntry entry) async {
    if (byId(entry.id) != null) return;
    _entries.add(entry);
    notifyListeners();
    await save();
  }

  void markOpened(String id) {
    final entry = byId(id);
    if (entry == null) return;
    entry.lastOpenedAt = DateTime.now();
    notifyListeners();
    _scheduleSave();
  }

  /// Called often while scrolling: saving is debounced.
  void updatePosition(String id, ReadingPosition position) {
    final entry = byId(id);
    if (entry == null || entry.position == position) return;
    entry.position = position;
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), save);
  }

  /// Writes `library.json` (atomically, via a temp file). Saves are
  /// queued so two writes never race on the temp file.
  Future<void> save() {
    _saveTimer?.cancel();
    final previous = _saving;
    final next = previous == null ? _write() : previous.then((_) => _write());
    final tracked = next.catchError(
      (Object e) => debugPrint('Saving library failed: $e'),
    );
    _saving = tracked;
    tracked.whenComplete(() {
      if (identical(_saving, tracked)) _saving = null;
    });
    return next;
  }

  /// The save in progress, if any.
  Future<void>? _saving;

  Future<void> _write() async {
    await directory.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'books': [for (final e in _entries) e.toJson()],
      }),
    );
    await tmp.rename(_file.path);
  }

  Future<String?> _writeCover(String id, _BookSummary summary) async {
    final bytes = summary.cover;
    final source = summary.metadata.coverImagePath;
    if (bytes == null || source == null) return null;
    await _coversDir.create(recursive: true);
    final ext = p.extension(source).isEmpty ? '.img' : p.extension(source);
    // New name each time so Flutter's image cache doesn't show a stale cover.
    final file = File(
      p.join(
        _coversDir.path,
        '$id-${DateTime.now().millisecondsSinceEpoch}$ext',
      ),
    );
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<void> _deleteOrphanCovers() async {
    if (!await _coversDir.exists()) return;
    final used = _entries.map((e) => e.coverFile).whereType<String>().toSet();
    await for (final f in _coversDir.list()) {
      if (f is File && !used.contains(f.path)) await f.delete();
    }
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) save();
    super.dispose();
  }
}
