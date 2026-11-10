import '../app/reader_settings.dart';
import '../tts/read_aloud_controller.dart';
import 'translation_controller.dart';
import 'translation_model.dart';

/// Translates the sentence being read aloud, when reading is paused or for
/// every sentence ([ReaderSettings.readAloudTranslation]). A translation
/// stays shown while reading goes on, until the next one replaces it; one
/// still running when reading moves on is cancelled. Independent of the
/// side panel's translation.
class ReadAloudTranslation {
  ReadAloudTranslation({
    required this.readAloud,
    required this.settings,
    required TranslationModel model,
    required String source,
  }) : translation = TranslationController(
         model: model,
         settings: settings,
         source: source,
         readAloud: true,
       ) {
    readAloud.addListener(_update);
    settings.addListener(_update);
    _update();
  }

  final ReadAloudController readAloud;
  final ReaderSettings settings;
  final TranslationController translation;

  /// Sentence whose translation is shown (or on its way).
  SentenceRef? _shown;

  void _update() {
    final ref = readAloud.current;
    final mode = settings.readAloudTranslation;
    if (mode == ReadAloudTranslateMode.off || ref == null) {
      if (_shown != null) {
        _shown = null;
        translation.close();
      }
      return;
    }
    final translateNow =
        mode == ReadAloudTranslateMode.always ||
        readAloud.state == ReadAloudState.paused;
    if (!translateNow || ref == _shown) return;
    final wanted = ref;
    _shown = wanted;
    final text = readAloud.textOf(wanted);
    final paragraph = wanted.isTitle
        ? null
        : readAloud.book.chapters[wanted.chapter].blocks[wanted.block].text;
    translation.translate(text, context: paragraph);
  }

  void dispose() {
    readAloud.removeListener(_update);
    settings.removeListener(_update);
    translation.dispose();
  }
}
