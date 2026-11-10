import 'dart:async';

import 'package:epub_reader/translate/translation_model.dart';
import 'package:epub_reader/translate/translator.dart';

/// Answers each request with [pieces] (or `[target] text` by default),
/// one piece per microtask, and records the requests.
class FakeTranslator implements Translator {
  FakeTranslator({this.pieces, this.error});

  final List<String>? pieces;
  final Object? error;
  final requests = <TranslationRequest>[];
  var cancelled = 0;

  @override
  Stream<String> translate(TranslationRequest request) {
    requests.add(request);
    late final StreamController<String> out;
    var stop = false;
    out = StreamController<String>(
      onListen: () async {
        for (final p in pieces ?? ['[${request.target}] ', request.text]) {
          await Future<void>.delayed(Duration.zero);
          if (stop) return;
          out.add(p);
        }
        if (error != null) out.addError(error!);
        await out.close();
      },
      onCancel: () {
        stop = true;
        cancelled++;
      },
    );
    return out.stream;
  }
}

class FakeTranslationModel extends TranslationModel {
  FakeTranslationModel({bool installed = true, Translator? translator})
    : _status = installed ? LlmFileStatus.ready : LlmFileStatus.missing,
      translatorUsed = translator ?? FakeTranslator();

  LlmFileStatus _status;
  final Translator translatorUsed;
  var downloads = 0;
  var unloads = 0;

  @override
  LlmFileStatus get status => _status;
  @override
  double? get progress => null;
  @override
  String? get error => null;
  @override
  String get displayName => 'Fake LLM';
  @override
  String get approximateSize => '1 KB';
  @override
  bool get isStarting => false;

  @override
  Future<void> download() async {
    downloads++;
    _status = LlmFileStatus.ready;
    notifyListeners();
  }

  @override
  void cancelDownload() {}

  @override
  Future<Translator> translator() async {
    if (!isReady) throw TranslationException('not installed');
    return translatorUsed;
  }

  @override
  Future<void> unload() async => unloads++;
}
