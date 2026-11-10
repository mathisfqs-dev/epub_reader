import 'dart:io';

import 'package:epub_reader/library/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const alice = 'test/fixtures/books/alice_wonderland_images_epub3.epub';
const candide = 'test/fixtures/books/candide_fr_epub3.epub';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('library_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('adds a book with its metadata and cover', () async {
    final store = LibraryStore(dir);
    expect(await store.addBook(alice), AddResult.added);

    final entry = store.entries.single;
    expect(entry.title, "Alice's Adventures in Wonderland");
    expect(entry.authors, ['Lewis Carroll']);
    expect(entry.language, 'en');
    expect(entry.chapterCount, 13);
    expect(entry.path, p.absolute(alice));
    expect(entry.fileExists, isTrue);
    expect(File(entry.coverFile!).existsSync(), isTrue);
  });

  test('the same file is not added twice', () async {
    final store = LibraryStore(dir);
    await store.addBook(alice);
    expect(await store.addBook(alice), AddResult.alreadyInLibrary);
    expect(store.entries, hasLength(1));
  });

  test('entries and reading position survive a restart', () async {
    final store = LibraryStore(dir);
    await store.addBook(alice);
    await store.addBook(candide);
    final id = store.entries.firstWhere((e) => e.language == 'fr').id;
    store.updatePosition(id, const ReadingPosition(chapter: 7, block: 3));
    store.markOpened(id);
    await store.save();

    final reloaded = LibraryStore(dir);
    await reloaded.load();
    expect(reloaded.entries, hasLength(2));
    expect(reloaded.entries.first.id, id, reason: 'last opened comes first');
    expect(
      reloaded.byId(id)!.position,
      const ReadingPosition(chapter: 7, block: 3),
    );
  });

  test('remove and undo', () async {
    final store = LibraryStore(dir);
    await store.addBook(alice);
    final id = store.entries.single.id;
    final removed = store.remove(id);
    await store.save();
    expect(store.entries, isEmpty);
    expect(
      File(alice).existsSync(),
      isTrue,
      reason: 'the EPUB is never deleted',
    );

    await store.restore(removed!);
    expect(store.byId(id), isNotNull);
    expect(File(store.byId(id)!.coverFile!).existsSync(), isTrue);
  });

  test('a moved file is detected and can be relinked', () async {
    final copy = p.join(dir.path, 'alice.epub');
    await File(alice).copy(copy);
    final store = LibraryStore(dir);
    await store.addBook(copy);
    final entry = store.entries.single;
    store.updatePosition(entry.id, const ReadingPosition(chapter: 4, block: 2));

    await File(copy).rename(p.join(dir.path, 'moved.epub'));
    expect(entry.fileExists, isFalse);

    await store.relink(entry.id, p.join(dir.path, 'moved.epub'));
    expect(entry.fileExists, isTrue);
    expect(entry.position, const ReadingPosition(chapter: 4, block: 2));
  });

  test('an invalid file is rejected', () async {
    final bad = File(p.join(dir.path, 'bad.epub'));
    await bad.writeAsString('not a zip');
    final store = LibraryStore(dir);
    await expectLater(store.addBook(bad.path), throwsA(anything));
    expect(store.entries, isEmpty);
  });
}
