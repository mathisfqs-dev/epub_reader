import 'dart:io';

import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/library/library_store.dart';
import 'package:epub_reader/main.dart';
import 'package:epub_reader/reader/reader_screen.dart';
import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/pocket_model.dart';
import 'package:epub_reader/tts/speech_models.dart';
import 'package:epub_reader/tts/voice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('app_test'));
  tearDown(() async => dir.delete(recursive: true));

  testWidgets('empty library offers to add a book', (tester) async {
    await tester.pumpWidget(
      EpubReaderApp(
        settings: ReaderSettings.memory(),
        library: LibraryStore(dir),
      ),
    );
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('No books yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add book'), findsNWidgets(2));
  });

  testWidgets('library shows books, removes and restores them', (tester) async {
    final library = LibraryStore(dir);
    await tester.runAsync(
      () => library.addBook('test/fixtures/books/candide_fr_epub3.epub'),
    );
    await tester.pumpWidget(
      EpubReaderApp(settings: ReaderSettings.memory(), library: library),
    );
    expect(find.text("Candide, ou l'optimisme"), findsWidgets);
    expect(find.text('Voltaire'), findsOneWidget);

    await tester.tap(find.byTooltip('Book options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from library'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('No books yet'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Voltaire'), findsOneWidget);
  });

  testWidgets('tapping a book opens the reader', (tester) async {
    final library = LibraryStore(dir);
    await tester.runAsync(
      () => library.addBook('test/fixtures/books/candide_fr_epub3.epub'),
    );
    await tester.pumpWidget(
      EpubReaderApp(settings: ReaderSettings.memory(), library: library),
    );
    await tester.tap(find.text('Voltaire'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReaderScreen), findsOneWidget);
    // The book is parsed in a background isolate.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderView), findsOneWidget);
  });

  testWidgets('the home button chooses the read-aloud model', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = ReaderSettings.memory();
    final models = Directory('${dir.path}/models');
    final speech = SpeechModels(
      settings: settings,
      kokoro: KokoroModel(models),
      pocket: PocketModel(models),
    );
    await tester.pumpWidget(
      EpubReaderApp(
        settings: settings,
        library: LibraryStore(dir),
        speech: speech,
      ),
    );
    await tester.tap(find.text('Voice: Kokoro'));
    await tester.pumpAndSettle();
    expect(find.text('Read-aloud voices'), findsOneWidget);
    expect(find.text('Download (350 MB)'), findsOneWidget);
    expect(find.text('Install from a folder…'), findsOneWidget);

    await tester.tap(find.text('Pocket TTS'));
    await tester.pumpAndSettle();
    expect(settings.ttsModel, TtsModelKind.pocket);
    expect(find.text('In use'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Read-aloud voices'), findsNothing);
    expect(find.text('Voice: Pocket TTS'), findsOneWidget);
  });
}
