import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/reader_settings.dart';
import '../dictionary/dictionaries.dart';
import '../dictionary/word_lookup.dart';
import 'translation_model.dart';
import 'translator.dart';

enum TranslationPhase {
  /// The model must be downloaded first.
  needsModel,

  /// Waiting for the model (loading) or for the first words.
  starting,
  streaming,
  done,
  failed,
}

/// The translation shown in a reader's side panel: what is translated, into
/// which language, and the text received so far. When a single word is
/// translated and [dictionaries] has the book's language, the word is also
/// looked up in the dictionary (base form, grammar, definitions).
class TranslationController extends ChangeNotifier {
  TranslationController({
    required this.model,
    required this.settings,
    required this.source,
    this.readAloud = false,
    this.dictionaries,
  }) {
    model.addListener(_onModel);
    dictionaries?.addListener(_onDictionaries);
  }

  final TranslationModel model;
  final ReaderSettings settings;

  /// Language of the book.
  final String source;

  /// Translates for the read-aloud bar, whose target language is remembered
  /// apart from the side panel's.
  final bool readAloud;

  final Dictionaries? dictionaries;

  TranslationRequest? _request;
  bool _truncated = false;
  String _output = '';
  TranslationPhase _phase = TranslationPhase.starting;
  String? _error;
  StreamSubscription<String>? _subscription;
  int _generation = 0;

  String? _word;
  String? _sentence;
  List<WordAnalysis>? _analyses;
  String? _wordError;
  bool _lookingUp = false;
  int _wordGeneration = 0;

  /// What is being translated; null when the panel is closed.
  TranslationRequest? get request => _request;
  bool get isOpen => _request != null;

  /// The selection was longer than [TranslationRequest.maxLength] and only
  /// its beginning is translated.
  bool get truncated => _truncated;
  String get output => _output;
  TranslationPhase get phase => _phase;
  String? get error => _error;
  bool get isBusy =>
      _phase == TranslationPhase.starting ||
      _phase == TranslationPhase.streaming;

  /// The selected word, when the selection is one word of a language with
  /// a dictionary; null otherwise.
  String? get word => _word;

  /// What the dictionary says about [word]; null until looked up (or while
  /// the dictionary isn't installed).
  List<WordAnalysis>? get analyses => _analyses;
  bool get isLookingUp => _lookingUp;
  String? get wordError => _wordError;

  String get target => settings.translationTarget(source, readAloud: readAloud);

  /// Translates [text], with the paragraph around it as [context]; a single
  /// word is also looked up, with the [sentence] it is in.
  void translate(String text, {String? context, String? sentence}) {
    var passage = text.trim();
    if (passage.isEmpty) return;
    _truncated = passage.length > TranslationRequest.maxLength;
    if (_truncated) {
      passage = passage.substring(0, TranslationRequest.maxLength);
    }
    _request = TranslationRequest(
      text: passage,
      source: source,
      target: target,
      context: _truncated ? null : context,
    );
    _startLookup(passage, sentence ?? context);
    _run();
  }

  void _startLookup(String text, String? sentence) {
    _wordGeneration++;
    _analyses = null;
    _wordError = null;
    _lookingUp = false;
    _sentence = sentence;
    _word =
        (dictionaries?.supports(source) ?? false) &&
            WordLookup.isSingleWord(text)
        ? WordLookup.cleanWord(text)
        : null;
    if (_word != null) _lookUp();
  }

  Future<void> _lookUp() async {
    final generation = _wordGeneration;
    final word = _word;
    final dictionaries = this.dictionaries;
    if (word == null || dictionaries == null) return;
    if (!dictionaries.isReady(source)) return; // the panel offers to install
    _lookingUp = true;
    notifyListeners();
    try {
      final lookup = await dictionaries.lookup(source);
      final found = await lookup?.lookUp(word, sentence: _sentence);
      if (generation != _wordGeneration) return;
      _analyses = found ?? const [];
    } catch (e) {
      if (generation == _wordGeneration) _wordError = '$e';
    } finally {
      if (generation == _wordGeneration) {
        _lookingUp = false;
        notifyListeners();
      }
    }
  }

  void _onDictionaries() {
    // The dictionary was just installed: look up the word waiting.
    if (_word != null &&
        _analyses == null &&
        !_lookingUp &&
        dictionaries!.isReady(source)) {
      _lookUp();
    } else {
      notifyListeners();
    }
  }

  /// Changes the target language (remembered for this book language) and
  /// translates again.
  set target(String code) {
    if (code == target) return;
    settings.setTranslationTarget(source, code, readAloud: readAloud);
    final request = _request;
    if (request == null) {
      notifyListeners();
      return;
    }
    _request = request.copyWith(target: code);
    _run();
  }

  void retry() {
    if (_request != null) _run();
  }

  void close() {
    _generation++;
    _subscription?.cancel();
    _subscription = null;
    _request = null;
    _output = '';
    _error = null;
    _wordGeneration++;
    _word = null;
    _analyses = null;
    _lookingUp = false;
    notifyListeners();
  }

  Future<void> _run() async {
    final generation = ++_generation;
    // Not awaited: events of the old stream are ignored by generation.
    _subscription?.cancel();
    _subscription = null;
    _output = '';
    _error = null;
    if (!model.isReady) {
      _set(TranslationPhase.needsModel);
      return;
    }
    _set(TranslationPhase.starting);
    try {
      final translator = await model.translator();
      if (generation != _generation) return;
      _subscription = translator
          .translate(_request!)
          .listen(
            (piece) {
              if (generation != _generation) return;
              _output += piece;
              _set(TranslationPhase.streaming);
            },
            onError: (Object e) {
              if (generation != _generation) return;
              _fail(e);
            },
            onDone: () {
              if (generation != _generation || !isBusy) return;
              _subscription = null;
              _output = _output.trim();
              _set(TranslationPhase.done);
            },
            cancelOnError: true,
          );
    } catch (e) {
      if (generation == _generation) _fail(e);
    }
  }

  void _fail(Object e) {
    _error = e is TranslationException ? e.message : '$e';
    _set(TranslationPhase.failed);
  }

  void _set(TranslationPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _onModel() {
    // The model was just downloaded: translate what is waiting.
    if (_phase == TranslationPhase.needsModel && model.isReady && isOpen) {
      _run();
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _generation++;
    _subscription?.cancel();
    _wordGeneration++;
    model.removeListener(_onModel);
    dictionaries?.removeListener(_onDictionaries);
    super.dispose();
  }
}
