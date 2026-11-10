import 'package:flutter/foundation.dart';

import '../app/reader_settings.dart';
import 'kokoro_model.dart';
import 'pocket_model.dart';
import 'voice.dart';

/// The read-aloud models and which one is used (saved in [settings]).
class SpeechModels extends ChangeNotifier {
  SpeechModels({
    required this.settings,
    required this.kokoro,
    required this.pocket,
  }) {
    settings.addListener(_onSettings);
    kokoro.addListener(notifyListeners);
    pocket.addListener(notifyListeners);
    _kind = settings.ttsModel;
  }

  final ReaderSettings settings;
  final KokoroModel kokoro;
  final PocketModel pocket;
  late TtsModelKind _kind;

  TtsModelKind get activeKind => settings.ttsModel;

  VoiceModel get active => modelOf(activeKind);

  VoiceModel modelOf(TtsModelKind kind) => switch (kind) {
    TtsModelKind.kokoro => kokoro,
    TtsModelKind.pocket => pocket,
  };

  void select(TtsModelKind kind) => settings.ttsModel = kind;

  void _onSettings() {
    if (settings.ttsModel == _kind) return;
    // Free the memory of the model we leave.
    switch (_kind) {
      case TtsModelKind.kokoro:
        kokoro.unload();
      case TtsModelKind.pocket:
        pocket.unload();
    }
    _kind = settings.ttsModel;
    notifyListeners();
  }

  /// The voice used for books in [language] with the active model.
  Voice voiceFor(String language) => voiceOf(active, language);

  /// The voice chosen for [language] in [model], or its default.
  Voice voiceOf(VoiceModel model, String language) =>
      settings.voiceIn(model, language);

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    kokoro.removeListener(notifyListeners);
    pocket.removeListener(notifyListeners);
    super.dispose();
  }
}
