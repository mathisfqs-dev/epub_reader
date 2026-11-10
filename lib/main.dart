import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app/app_scope.dart';
import 'app/reader_settings.dart';
import 'dictionary/dictionaries.dart';
import 'library/library_screen.dart';
import 'library/library_store.dart';
import 'theme/reader_theme.dart';
import 'translate/translation_model.dart';
import 'tts/kokoro_model.dart';
import 'tts/pocket_model.dart';
import 'tts/speech_models.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await ReaderSettings.load();
  final library = await LibraryStore.open();
  final models = Directory(p.join(library.directory.path, 'models'));
  final speech = SpeechModels(
    settings: settings,
    kokoro: KokoroModel(models),
    pocket: PocketModel(models),
  );
  final translation = LlamaTranslationModel(models);
  final dictionaries = WiktionaryDictionaries(
    Directory(p.join(models.path, 'dictionaries')),
  );
  // Stop llama-server with the app (a crash leaves it to the next start).
  AppLifecycleListener(
    onExitRequested: () async {
      await translation.unload();
      return AppExitResponse.exit;
    },
  );
  runApp(
    EpubReaderApp(
      settings: settings,
      library: library,
      speech: speech,
      translation: translation,
      dictionaries: dictionaries,
    ),
  );
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({
    super.key,
    required this.settings,
    required this.library,
    this.speech,
    this.translation,
    this.dictionaries,
  });

  final ReaderSettings settings;
  final LibraryStore library;
  final SpeechModels? speech;
  final TranslationModel? translation;
  final Dictionaries? dictionaries;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      library: library,
      speech: speech,
      translation: translation,
      dictionaries: dictionaries,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final mode = settings.themeMode;
          final auto = mode == ReaderThemeMode.auto;
          return MaterialApp(
            title: 'EPUB Reader',
            debugShowCheckedModeBanner: false,
            theme:
                (auto
                        ? ReaderTheme.light
                        : ReaderTheme.forMode(mode, Brightness.light))
                    .toThemeData(),
            darkTheme:
                (auto
                        ? ReaderTheme.dark
                        : ReaderTheme.forMode(mode, Brightness.dark))
                    .toThemeData(),
            themeMode: ThemeMode.system,
            home: const LibraryScreen(),
          );
        },
      ),
    );
  }
}
