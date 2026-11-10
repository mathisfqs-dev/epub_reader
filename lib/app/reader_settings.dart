import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/reader_theme.dart';
import '../translate/languages.dart';
import '../tts/kokoro_voices.dart';
import '../tts/voice.dart';

/// Reading font. [family] null means the system font.
enum ReaderFont {
  book('Book', 'Iowan Old Style'),
  serif('Serif', 'Georgia'),
  sans('Sans', null);

  const ReaderFont(this.label, this.family);
  final String label;
  final String? family;
}

/// When the sentence read aloud is translated under the read-aloud bar.
enum ReadAloudTranslateMode {
  off('Off'),
  onPause('When paused'),
  always('Every sentence');

  const ReadAloudTranslateMode(this.label);
  final String label;
}

/// Appearance settings, persisted with shared_preferences.
class ReaderSettings extends ChangeNotifier {
  ReaderSettings._(this._prefs) {
    _themeMode = _enumFrom(
      ReaderThemeMode.values,
      _prefs?.getString(_kTheme),
      ReaderThemeMode.auto,
    );
    _font = _enumFrom(
      ReaderFont.values,
      _prefs?.getString(_kFont),
      ReaderFont.book,
    );
    _fontSize = _prefs?.getDouble(_kSize) ?? defaultFontSize;
    _lineHeight = _prefs?.getDouble(_kLineHeight) ?? defaultLineHeight;
    _justify = _prefs?.getBool(_kJustify) ?? false;
    _speechSpeed = _prefs?.getDouble(_kSpeed) ?? 1.0;
    _ttsModel = _enumFrom(
      TtsModelKind.values,
      _prefs?.getString(_kModel),
      TtsModelKind.kokoro,
    );
    _readAloudTranslation = _enumFrom(
      ReadAloudTranslateMode.values,
      _prefs?.getString(_kReadAloudTranslation),
      // Before the modes, it was on (when paused) or off.
      _prefs?.getBool(_kReadAloudTranslate) == true
          ? ReadAloudTranslateMode.onPause
          : ReadAloudTranslateMode.off,
    );
    _autoTranslateSelection = _prefs?.getBool(_kAutoTranslate) ?? false;
  }

  /// In-memory settings with defaults (tests).
  ReaderSettings.memory() : this._(null);

  static Future<ReaderSettings> load() async =>
      ReaderSettings._(await SharedPreferences.getInstance());

  static const _kTheme = 'reader.theme';
  static const _kFont = 'reader.font';
  static const _kSize = 'reader.fontSize';
  static const _kLineHeight = 'reader.lineHeight';
  static const _kJustify = 'reader.justify';
  static const _kSpeed = 'tts.speed';
  static const _kVoice = 'tts.voice.';
  static const _kModel = 'tts.model';
  static const _kTarget = 'translate.target.';
  static const _kReadAloudTarget = 'readAloud.translate.target.';
  static const _kReadAloudTranslate = 'readAloud.translate';
  static const _kReadAloudTranslation = 'readAloud.translation';
  static const _kAutoTranslate = 'translate.autoSelection';

  static const speechSpeeds = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.5];

  static const defaultFontSize = 19.0;
  static const minFontSize = 13.0;
  static const maxFontSize = 32.0;
  static const defaultLineHeight = 1.55;
  static const minLineHeight = 1.2;
  static const maxLineHeight = 2.2;

  final SharedPreferences? _prefs;

  late ReaderThemeMode _themeMode;
  late ReaderFont _font;
  late double _fontSize;
  late double _lineHeight;
  late bool _justify;
  late double _speechSpeed;
  late TtsModelKind _ttsModel;
  late ReadAloudTranslateMode _readAloudTranslation;
  late bool _autoTranslateSelection;
  final _voices = <String, String>{};
  final _targets = <String, String>{};

  ReaderThemeMode get themeMode => _themeMode;
  ReaderFont get font => _font;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  bool get justify => _justify;

  /// Read-aloud speed, 1.0 = normal.
  double get speechSpeed => _speechSpeed;

  /// Read-aloud model used by the reader.
  TtsModelKind get ttsModel => _ttsModel;

  /// Chosen Kokoro voice for books in [language] (`en`, `fr`…).
  KokoroVoice voiceFor(String language) {
    final name = voiceKey(TtsModelKind.kokoro, language);
    return (name == null ? null : voiceNamed(name)) ??
        defaultVoiceFor(language);
  }

  /// Chosen voice of [model] for books in [language], or its default.
  Voice voiceIn(VoiceModel model, String language) {
    final key = voiceKey(model.kind, language);
    return (key == null ? null : model.voiceByKey(key)) ??
        model.defaultVoiceFor(language);
  }

  /// Saved voice key of [model] for [language], if any.
  String? voiceKey(TtsModelKind model, String language) {
    final key = _voicePref(model, language);
    return _voices[key] ?? _prefs?.getString(key);
  }

  // Kokoro keeps its original keys.
  static String _voicePref(TtsModelKind model, String language) =>
      model == TtsModelKind.kokoro
      ? '$_kVoice$language'
      : 'tts.${model.name}.voice.$language';

  bool get canIncreaseFont => _fontSize < maxFontSize;
  bool get canDecreaseFont => _fontSize > minFontSize;
  bool get canIncreaseLineHeight => _lineHeight < maxLineHeight - 0.001;
  bool get canDecreaseLineHeight => _lineHeight > minLineHeight + 0.001;

  set themeMode(ReaderThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    _prefs?.setString(_kTheme, value.name);
    notifyListeners();
  }

  set font(ReaderFont value) {
    if (value == _font) return;
    _font = value;
    _prefs?.setString(_kFont, value.name);
    notifyListeners();
  }

  void changeFontSize(double delta) {
    final next = (_fontSize + delta).clamp(minFontSize, maxFontSize);
    if (next == _fontSize) return;
    _fontSize = next;
    _prefs?.setDouble(_kSize, next);
    notifyListeners();
  }

  void changeLineHeight(double delta) {
    final next = double.parse(
      (_lineHeight + delta)
          .clamp(minLineHeight, maxLineHeight)
          .toStringAsFixed(2),
    );
    if (next == _lineHeight) return;
    _lineHeight = next;
    _prefs?.setDouble(_kLineHeight, next);
    notifyListeners();
  }

  set justify(bool value) {
    if (value == _justify) return;
    _justify = value;
    _prefs?.setBool(_kJustify, value);
    notifyListeners();
  }

  set speechSpeed(double value) {
    if (value == _speechSpeed) return;
    _speechSpeed = value;
    _prefs?.setDouble(_kSpeed, value);
    notifyListeners();
  }

  set ttsModel(TtsModelKind value) {
    if (value == _ttsModel) return;
    _ttsModel = value;
    _prefs?.setString(_kModel, value.name);
    notifyListeners();
  }

  /// While the translation panel is open, translate each new selection
  /// without clicking "Translate".
  bool get autoTranslateSelection => _autoTranslateSelection;

  set autoTranslateSelection(bool value) {
    if (value == _autoTranslateSelection) return;
    _autoTranslateSelection = value;
    _prefs?.setBool(_kAutoTranslate, value);
    notifyListeners();
  }

  /// When the sentence read aloud is translated.
  ReadAloudTranslateMode get readAloudTranslation => _readAloudTranslation;

  set readAloudTranslation(ReadAloudTranslateMode value) {
    if (value == _readAloudTranslation) return;
    _readAloudTranslation = value;
    _prefs?.setString(_kReadAloudTranslation, value.name);
    notifyListeners();
  }

  /// Language that books in [source] are translated into, in the side panel
  /// or, with [readAloud], under the read-aloud bar (each remembered apart).
  String translationTarget(String source, {bool readAloud = false}) {
    final key = _targetKey(source, readAloud);
    return _targets[key] ??
        _prefs?.getString(key) ??
        TranslationLanguage.defaultTargetFor(source);
  }

  void setTranslationTarget(
    String source,
    String target, {
    bool readAloud = false,
  }) {
    if (translationTarget(source, readAloud: readAloud) == target) return;
    final key = _targetKey(source, readAloud);
    _targets[key] = target;
    _prefs?.setString(key, target);
    notifyListeners();
  }

  /// Remembers [voice] for books in [language] (for the voice's model).
  void setVoice(String language, Voice voice) {
    final key = _voicePref(voice.model, language);
    if (voiceKey(voice.model, language) == voice.key) return;
    _voices[key] = voice.key;
    _prefs?.setString(key, voice.key);
    notifyListeners();
  }

  static String _targetKey(String source, bool readAloud) =>
      '${readAloud ? _kReadAloudTarget : _kTarget}$source';

  static T _enumFrom<T extends Enum>(
    List<T> values,
    String? name,
    T fallback,
  ) => values.where((v) => v.name == name).firstOrNull ?? fallback;
}
