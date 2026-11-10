import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'kokoro_voices.dart' as voices;
import 'tts_engine.dart';
import 'voice.dart';

enum ModelStatus { missing, downloading, extracting, ready, failed }

/// The Kokoro voice model on disk: checks it, downloads and extracts it
/// (once, ~350 MB from the sherpa-onnx GitHub releases), and starts the
/// [TtsEngine] on demand.
class KokoroModel extends ChangeNotifier implements VoiceModel {
  KokoroModel(this.modelsDirectory) {
    _status = _complete() ? ModelStatus.ready : ModelStatus.missing;
  }

  static const name = 'kokoro-multi-lang-v1_0';
  static const url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$name.tar.bz2';
  static const approximateSize = '350 MB';

  final Directory modelsDirectory;

  late ModelStatus _status;
  double? _progress;
  String? _error;
  HttpClient? _client;
  Future<TtsEngine>? _engine;

  KokoroFiles get files => KokoroFiles(p.join(modelsDirectory.path, name));
  ModelStatus get status => _status;

  /// Download progress in [0, 1], null if unknown.
  double? get progress => _progress;
  String? get error => _error;
  @override
  bool get isReady => _status == ModelStatus.ready;

  @override
  TtsModelKind get kind => TtsModelKind.kokoro;

  @override
  bool get supportsSpeed => true;

  @override
  List<Voice> voicesFor(String language) => voices.voicesFor(language);

  @override
  Voice defaultVoiceFor(String language) => voices.defaultVoiceFor(language);

  @override
  Voice? voiceByKey(String key) => voices.voiceNamed(key);
  bool get isBusy =>
      _status == ModelStatus.downloading || _status == ModelStatus.extracting;

  bool _complete() => files.required.every((f) => File(f).existsSync());

  /// The engine, started on first use and shared by every book.
  @override
  Future<TtsEngine> engine() {
    if (!isReady) return Future.error(StateError('Voice model not installed'));
    return _engine ??= TtsEngine.start(files).catchError((Object e) {
      _engine = null;
      throw e;
    });
  }

  Future<void> download() async {
    if (isBusy || isReady) return;
    _set(ModelStatus.downloading, progress: 0);
    final archive = File(p.join(modelsDirectory.path, '$name.tar.bz2.part'));
    IOSink? sink;
    try {
      await modelsDirectory.create(recursive: true);
      _client = HttpClient();
      final request = await _client!.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final total = response.contentLength;
      var received = 0;
      sink = archive.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final next = received / total;
          if (next - (_progress ?? 0) > 0.005) {
            _set(ModelStatus.downloading, progress: next);
          }
        }
      }
      await sink.close();
      sink = null;

      _set(ModelStatus.extracting);
      // The system tar (macOS, Linux, Windows 10+) is much faster than a
      // pure-Dart bzip2 decoder on 350 MB.
      final result = await Process.run('tar', [
        '-xjf',
        archive.path,
        '-C',
        modelsDirectory.path,
      ]);
      if (result.exitCode != 0) {
        throw ProcessException('tar', [], '${result.stderr}');
      }
      if (!_complete()) throw StateError('The archive is missing model files');
      _set(ModelStatus.ready);
    } catch (e) {
      if (_status != ModelStatus.missing) _set(ModelStatus.failed, error: '$e');
    } finally {
      await sink?.close().catchError((_) {});
      _client?.close(force: true);
      _client = null;
      if (archive.existsSync()) archive.deleteSync();
    }
  }

  /// Stops the engine to free its memory; [engine] starts it again.
  void unload() {
    final engine = _engine;
    _engine = null;
    engine?.then((e) => e.dispose(), onError: (_) {});
  }

  void cancelDownload() {
    if (_status != ModelStatus.downloading) return;
    _set(ModelStatus.missing);
    _client?.close(force: true);
  }

  void _set(ModelStatus status, {double? progress, String? error}) {
    _status = status;
    _progress = progress;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.close(force: true);
    _engine?.then((e) => e.dispose(), onError: (_) {});
    super.dispose();
  }
}
