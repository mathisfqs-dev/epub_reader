import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'llama_server.dart';
import 'translator.dart';

enum LlmFileStatus { missing, downloading, ready, failed }

/// The translation model as the UI sees it: is it installed, can it be
/// downloaded, and a [Translator] once it runs.
abstract class TranslationModel extends ChangeNotifier {
  LlmFileStatus get status;

  /// Download progress in [0, 1], null if unknown.
  double? get progress;
  String? get error;
  String get displayName;
  String get approximateSize;

  bool get isReady => status == LlmFileStatus.ready;

  /// True while the model is being loaded into memory.
  bool get isStarting;

  Future<void> download();
  void cancelDownload();

  /// A translator, starting the model first if needed. Throws a
  /// [TranslationException] if it can't.
  Future<Translator> translator();

  /// Frees the model's memory; [translator] starts it again.
  Future<void> unload();
}

/// Gemma 3 4B (GGUF, Q4_K_M) run by a llama-server process.
///
/// The server starts on the first translation and stops after [idleTimeout]
/// without one, or when the app quits. If no `llama-server` is installed on
/// the machine (Homebrew, bundle, or `$LLAMA_SERVER`), [download] also fetches
/// the official prebuilt `llama-server` binary into `<appSupport>/bin/`.
class LlamaTranslationModel extends TranslationModel {
  LlamaTranslationModel(
    this.modelsDirectory, {
    this.idleTimeout = const Duration(minutes: 10),
    this.modelUrl = url,
    String? serverArchiveUrl,
    this.findServer,
  }) : serverArchiveUrl = serverArchiveUrl ?? LlamaServer.releaseUrl {
    _status = _complete() ? LlmFileStatus.ready : LlmFileStatus.missing;
    // A server left running by a crash of the app holds ~3 GB.
    LlamaServer.stopStale(_pidFile).catchError((_) {});
  }

  static const fileName = 'gemma-3-4b-it-Q4_K_M.gguf';
  static const url =
      'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/$fileName';

  final Directory modelsDirectory;
  final Duration idleTimeout;
  final String modelUrl;
  final String serverArchiveUrl;
  final String? Function()? findServer;

  late LlmFileStatus _status;
  double? _progress;
  String? _error;
  HttpClient? _client;
  Future<LlamaServer>? _server;
  bool _starting = false;
  Timer? _idle;

  Directory get _directory => Directory(p.join(modelsDirectory.path, 'llm'));
  Directory get binDirectory =>
      Directory(p.join(modelsDirectory.parent.path, 'bin'));
  File get _modelFile => File(p.join(_directory.path, fileName));
  File get _pidFile => File(p.join(_directory.path, 'llama-server.pid'));

  /// llama-server's output, kept for debugging.
  File get logFile => File(p.join(_directory.path, 'llama-server.log'));

  String? _locateServer() =>
      findServer != null
          ? findServer!()
          : LlamaServer.find(extraDirectory: binDirectory.path);

  bool _complete() => _modelFile.existsSync() && _locateServer() != null;

  @override
  LlmFileStatus get status => _status;
  @override
  double? get progress => _progress;
  @override
  String? get error => _error;
  @override
  String get displayName => 'Gemma 3 4B';
  @override
  String get approximateSize => '2.5 GB';
  @override
  bool get isStarting => _starting;

  @override
  Future<Translator> translator() async {
    if (!isReady) throw TranslationException('The model is not installed.');
    _idle?.cancel();
    var server = await _running();
    if (!server.isRunning) {
      // It crashed or was stopped since: start a new one.
      _server = null;
      server = await _running();
    }
    _idle = Timer(idleTimeout, unload);
    return OpenAiChatTranslator(baseUri: server.baseUri, apiKey: server.apiKey);
  }

  /// The server, started once and shared; a failed start is retried on the
  /// next call.
  Future<LlamaServer> _running() async {
    final future = _server ??= _start();
    try {
      return await future;
    } catch (_) {
      if (identical(_server, future)) _server = null;
      rethrow;
    }
  }

  Future<LlamaServer> _start() async {
    var binary = _locateServer();
    if (binary == null) {
      _set(LlmFileStatus.missing);
      throw TranslationException(
        'llama-server is not installed. Download it from the translation panel.',
      );
    }
    _setStarting(true);
    try {
      return await LlamaServer.start(
        binary: binary,
        model: _modelFile.path,
        pidFile: _pidFile,
        logFile: logFile,
      );
    } on LlamaServerException catch (e) {
      debugPrint('llama-server failed: ${e.message}\n${e.log}');
      throw TranslationException(
        '${e.message} See ${logFile.path} for details.',
      );
    } finally {
      _setStarting(false);
    }
  }

  void _setStarting(bool value) {
    _starting = value;
    notifyListeners();
  }

  @override
  Future<void> unload() async {
    _idle?.cancel();
    final server = _server;
    _server = null;
    if (server == null) return;
    try {
      await (await server).stop();
    } catch (_) {
      // It never started.
    }
  }

  @override
  Future<void> download() async {
    if (_status == LlmFileStatus.downloading || isReady) return;
    _set(LlmFileStatus.downloading, progress: 0);
    try {
      await _directory.create(recursive: true);
      _client = HttpClient();
      if (_locateServer() == null) {
        await _downloadServer();
      }
      if (!_modelFile.existsSync()) {
        await _downloadModelFile();
      }
      if (!_complete()) {
        throw StateError('Download incomplete');
      }
      _set(LlmFileStatus.ready);
    } catch (e) {
      if (_status != LlmFileStatus.missing) {
        _set(LlmFileStatus.failed, error: '$e');
      }
    } finally {
      _client?.close(force: true);
      _client = null;
    }
  }

  Future<void> _downloadServer() async {
    final ext = serverArchiveUrl.endsWith('.zip') ? '.zip' : '.tar.gz';
    final archive = File(p.join(_directory.path, 'llama-server$ext.part'));
    IOSink? sink;
    try {
      if (archive.existsSync()) archive.deleteSync();
      final request = await _client!.getUrl(Uri.parse(serverArchiveUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          'HTTP ${response.statusCode}',
          uri: Uri.parse(serverArchiveUrl),
        );
      }
      final needsModel = !_modelFile.existsSync();
      final total = response.contentLength;
      var received = 0;
      sink = archive.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (!needsModel && total > 0) {
          final next = received / total;
          if (next - (_progress ?? 0) > 0.005) {
            _set(LlmFileStatus.downloading, progress: next);
          }
        }
      }
      await sink.close();
      sink = null;
      await LlamaServer.extractArchive(archive, binDirectory);
    } finally {
      await sink?.close().catchError((_) {});
      if (archive.existsSync()) archive.deleteSync();
    }
  }

  Future<void> _downloadModelFile() async {
    final part = File('${_modelFile.path}.part');
    IOSink? sink;
    try {
      // Resume a previous attempt.
      final have = part.existsSync() ? part.lengthSync() : 0;
      final request = await _client!.getUrl(Uri.parse(modelUrl));
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }
      final response = await request.close();
      final resumed = response.statusCode == 206;
      if (response.statusCode != 200 && !resumed) {
        throw HttpException(
          'HTTP ${response.statusCode}',
          uri: Uri.parse(modelUrl),
        );
      }
      final offset = resumed ? have : 0;
      final total = response.contentLength < 0
          ? -1
          : response.contentLength + offset;
      var received = offset;
      sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final next = received / total;
          if (next - (_progress ?? 0) > 0.002) {
            _set(LlmFileStatus.downloading, progress: next);
          }
        }
      }
      await sink.close();
      sink = null;
      if (total > 0 && part.lengthSync() != total) {
        throw StateError('Download incomplete');
      }
      await part.rename(_modelFile.path);
    } finally {
      await sink?.close().catchError((_) {});
    }
  }

  @override
  void cancelDownload() {
    if (_status != LlmFileStatus.downloading) return;
    _set(LlmFileStatus.missing);
    _client?.close(force: true);
  }

  void _set(LlmFileStatus status, {double? progress, String? error}) {
    _status = status;
    _progress = progress;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.close(force: true);
    unload();
    super.dispose();
  }
}
