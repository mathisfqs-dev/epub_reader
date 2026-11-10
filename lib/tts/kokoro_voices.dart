import 'voice.dart';

/// Kokoro v1.0 voices usable with the eSpeak phonemizer.
///
/// Speaker ids come from the model's `speaker2id` metadata
/// (kokoro-multi-lang-v1_0). Japanese and Chinese voices are left out: they
/// need other phonemizers.
class KokoroVoice implements Voice {
  const KokoroVoice(
    this.id,
    this.name,
    this.label,
    this.language,
    this.espeakVoice,
  );

  /// Speaker id (`sid`) in voices.bin.
  final int id;

  /// Kokoro name, e.g. `af_heart`.
  final String name;

  /// Display label, e.g. `Heart`.
  final String label;

  /// Language code: `en`, `fr`, `es`, `it`, `pt`, `hi`.
  @override
  final String language;

  /// eSpeak-NG voice used to phonemize text for this voice.
  final String espeakVoice;

  @override
  TtsModelKind get model => TtsModelKind.kokoro;

  @override
  String get key => name;

  @override
  bool get female => name[1] == 'f';

  String get accent => switch (name[0]) {
    'a' => 'US',
    'b' => 'UK',
    'f' => 'FR',
    'e' => 'ES',
    'i' => 'IT',
    'p' => 'BR',
    'h' => 'HI',
    _ => '',
  };

  /// e.g. `Heart · US`.
  @override
  String get description => '$label · $accent';

  @override
  String toString() => name;
}

const kokoroVoices = <KokoroVoice>[
  KokoroVoice(3, 'af_heart', 'Heart', 'en', 'en-us'),
  KokoroVoice(2, 'af_bella', 'Bella', 'en', 'en-us'),
  KokoroVoice(6, 'af_nicole', 'Nicole', 'en', 'en-us'),
  KokoroVoice(0, 'af_alloy', 'Alloy', 'en', 'en-us'),
  KokoroVoice(1, 'af_aoede', 'Aoede', 'en', 'en-us'),
  KokoroVoice(4, 'af_jessica', 'Jessica', 'en', 'en-us'),
  KokoroVoice(5, 'af_kore', 'Kore', 'en', 'en-us'),
  KokoroVoice(7, 'af_nova', 'Nova', 'en', 'en-us'),
  KokoroVoice(8, 'af_river', 'River', 'en', 'en-us'),
  KokoroVoice(9, 'af_sarah', 'Sarah', 'en', 'en-us'),
  KokoroVoice(10, 'af_sky', 'Sky', 'en', 'en-us'),
  KokoroVoice(16, 'am_michael', 'Michael', 'en', 'en-us'),
  KokoroVoice(13, 'am_eric', 'Eric', 'en', 'en-us'),
  KokoroVoice(14, 'am_fenrir', 'Fenrir', 'en', 'en-us'),
  KokoroVoice(15, 'am_liam', 'Liam', 'en', 'en-us'),
  KokoroVoice(11, 'am_adam', 'Adam', 'en', 'en-us'),
  KokoroVoice(12, 'am_echo', 'Echo', 'en', 'en-us'),
  KokoroVoice(17, 'am_onyx', 'Onyx', 'en', 'en-us'),
  KokoroVoice(18, 'am_puck', 'Puck', 'en', 'en-us'),
  KokoroVoice(19, 'am_santa', 'Santa', 'en', 'en-us'),
  KokoroVoice(21, 'bf_emma', 'Emma', 'en', 'en-gb-x-rp'),
  KokoroVoice(22, 'bf_isabella', 'Isabella', 'en', 'en-gb-x-rp'),
  KokoroVoice(20, 'bf_alice', 'Alice', 'en', 'en-gb-x-rp'),
  KokoroVoice(23, 'bf_lily', 'Lily', 'en', 'en-gb-x-rp'),
  KokoroVoice(26, 'bm_george', 'George', 'en', 'en-gb-x-rp'),
  KokoroVoice(25, 'bm_fable', 'Fable', 'en', 'en-gb-x-rp'),
  KokoroVoice(27, 'bm_lewis', 'Lewis', 'en', 'en-gb-x-rp'),
  KokoroVoice(24, 'bm_daniel', 'Daniel', 'en', 'en-gb-x-rp'),
  KokoroVoice(30, 'ff_siwis', 'Siwis', 'fr', 'fr'),
  KokoroVoice(28, 'ef_dora', 'Dora', 'es', 'es'),
  KokoroVoice(29, 'em_alex', 'Alex', 'es', 'es'),
  KokoroVoice(53, 'em_santa', 'Santa', 'es', 'es'),
  KokoroVoice(35, 'if_sara', 'Sara', 'it', 'it'),
  KokoroVoice(36, 'im_nicola', 'Nicola', 'it', 'it'),
  KokoroVoice(42, 'pf_dora', 'Dora', 'pt', 'pt-br'),
  KokoroVoice(43, 'pm_alex', 'Alex', 'pt', 'pt-br'),
  KokoroVoice(44, 'pm_santa', 'Santa', 'pt', 'pt-br'),
  KokoroVoice(31, 'hf_alpha', 'Alpha', 'hi', 'hi'),
  KokoroVoice(32, 'hf_beta', 'Beta', 'hi', 'hi'),
  KokoroVoice(33, 'hm_omega', 'Omega', 'hi', 'hi'),
  KokoroVoice(34, 'hm_psi', 'Psi', 'hi', 'hi'),
];

KokoroVoice? voiceNamed(String name) =>
    kokoroVoices.where((v) => v.name == name).firstOrNull;

/// Language code of a book (`en-US` → `en`), `en` if unknown.
String languageOf(String? bookLanguage) {
  final code = (bookLanguage ?? 'en').toLowerCase().split(RegExp('[-_]')).first;
  return kokoroVoices.any((v) => v.language == code) ? code : 'en';
}

/// Default voice for a language.
KokoroVoice defaultVoiceFor(String language) => kokoroVoices.firstWhere(
  (v) => v.language == language,
  orElse: () => kokoroVoices.first,
);

/// Voices of [language] first, then the others.
List<KokoroVoice> voicesFor(String language) => [
  ...kokoroVoices.where((v) => v.language == language),
  ...kokoroVoices.where((v) => v.language != language),
];
