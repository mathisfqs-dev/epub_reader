import 'package:flutter/foundation.dart';

import 'tts_engine.dart';

/// The read-aloud models the app can use.
enum TtsModelKind {
  kokoro('Kokoro'),
  pocket('Pocket TTS');

  const TtsModelKind(this.label);
  final String label;
}

/// A voice of one of the read-aloud models.
abstract interface class Voice {
  /// Model this voice belongs to.
  TtsModelKind get model;

  /// Stable identifier, saved in the settings.
  String get key;

  /// Language code: `en`, `fr`…
  String get language;

  /// Null when unknown.
  bool? get female;

  /// Menu label, e.g. `Heart · US`.
  String get description;
}

/// A read-aloud model: its voices and its engine.
abstract interface class VoiceModel implements Listenable {
  TtsModelKind get kind;

  /// Whether at least one voice can be used.
  bool get isReady;

  /// Whether [Synthesizer.synthesize] honours its speed argument.
  bool get supportsSpeed;

  /// Voices of [language] first, then the others.
  List<Voice> voicesFor(String language);

  /// The voice to use for [language] when none was chosen.
  Voice defaultVoiceFor(String language);

  Voice? voiceByKey(String key);

  /// The engine, started on first use.
  Future<Synthesizer> engine();
}

/// Language code of a book (`en-US` → `en`), `en` if unknown.
String languageCode(String? bookLanguage) {
  final code = (bookLanguage ?? '').toLowerCase().split(RegExp('[-_]')).first;
  return code.isEmpty ? 'en' : code;
}
