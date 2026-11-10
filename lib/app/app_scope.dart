import 'package:flutter/widgets.dart';

import '../dictionary/dictionaries.dart';
import '../library/library_store.dart';
import '../translate/translation_model.dart';
import '../tts/speech_models.dart';
import 'reader_settings.dart';

/// Gives widgets access to the app-wide state.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.library,
    this.speech,
    this.translation,
    this.dictionaries,
    required super.child,
  });

  final ReaderSettings settings;
  final LibraryStore library;

  /// The read-aloud models; null disables read-aloud (tests).
  final SpeechModels? speech;

  /// The translation model; null disables translation (tests).
  final TranslationModel? translation;

  /// Offline dictionaries for word lookups; null disables them (tests).
  final Dictionaries? dictionaries;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      settings != oldWidget.settings ||
      library != oldWidget.library ||
      speech != oldWidget.speech ||
      translation != oldWidget.translation ||
      dictionaries != oldWidget.dictionaries;
}
