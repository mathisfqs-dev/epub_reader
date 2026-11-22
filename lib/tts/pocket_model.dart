import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_clip.dart';
import 'kokoro_model.dart' show ModelStatus;
import 'pocket_text.dart';
import 'tts_engine.dart';
import 'voice.dart';

/// Language codes of Pocket TTS checkpoint names.
const _languageCodes = {
  'english': 'en',
  'french': 'fr',
  'german': 'de',
  'spanish': 'es',
  'italian': 'it',
  'portuguese': 'pt',
  'dutch': 'nl',
};

/// Display names of the languages, in the language itself.
const pocketLanguageNames = {
  'en': 'English',
  'fr': 'Français',
  'de': 'Deutsch',
  'es': 'Español',
  'it': 'Italiano',
  'pt': 'Português',
  'nl': 'Nederlands',
};

/// Archive names of the Pocket TTS language packs published on Hugging Face.
const pocketRemoteArchives = {
  'en': 'pocket-english-int8.tar.bz2',
  'fr': 'pocket-french-int8.tar.bz2',
  'de': 'pocket-german-int8.tar.bz2',
  'es': 'pocket-spanish-int8.tar.bz2',
};

/// Voices of Kyutai's catalog (kyutai/tts-voices) whose gender we know.
const _knownFemale = {
  'alba': true,
  'estelle': true,
  'lola': true,
  'fabien': false,
  'juergen': false,
};

/// One installed Pocket TTS model (one language), as written by
/// `pocket_tts_export/pack_sherpa.py`.
class PocketPack {
  PocketPack._({
    required this.directory,
    required this.language,
    required this.files,
    required this.rules,
    required this.recommendedFramesAfterEos,
    required this.temperature,
    required Map<String, String> voices,
  }) {
    this.voices = [
      for (final MapEntry(:key, :value) in voices.entries)
        PocketVoice(this, key, p.join(directory, value)),
    ];
  }

  /// Reads `pocket.json` in [directory]; null if it isn't a complete pack.
  static PocketPack? load(String directory) {
    try {
      final file = File(p.join(directory, 'pocket.json'));
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final name = (json['language'] as String).split('_').first;
      final language = _languageCodes[name] ?? name;
      final files = {
        for (final MapEntry(:key, :value)
            in (json['files'] as Map<String, dynamic>).entries)
          key: p.join(directory, value as String),
      };
      final voices = (json['voices'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(k, v as String),
      );
      final pack = PocketPack._(
        directory: directory,
        language: language,
        files: files,
        rules: PocketTextRules.fromJson(
          json['text'] as Map<String, dynamic>? ?? {},
        ),
        recommendedFramesAfterEos:
            json['model_recommended_frames_after_eos'] as int?,
        temperature: (json['default_temperature'] as num?)?.toDouble() ?? 0.3,
        voices: voices,
      );
      final complete =
          _requiredFiles.every((k) => File(files[k] ?? '').existsSync()) &&
          pack.voices.isNotEmpty &&
          pack.voices.every((v) => File(v.wav).existsSync());
      return complete ? pack : null;
    } on Object {
      return null;
    }
  }

  static const _requiredFiles = [
    'lm_main',
    'lm_flow',
    'encoder',
    'decoder',
    'text_conditioner',
    'vocab_json',
    'token_scores_json',
  ];

  final String directory;

  /// `fr`, `en`…
  final String language;

  /// Absolute paths by role (`lm_main`, `vocab_json`…).
  final Map<String, String> files;
  final PocketTextRules rules;
  final int? recommendedFramesAfterEos;
  final double temperature;
  late final List<PocketVoice> voices;

  String get languageName => pocketLanguageNames[language] ?? language;

  /// Upstream's rule for how long to keep generating after end of speech.
  int framesAfterEos(PreparedText text) =>
      recommendedFramesAfterEos ?? text.framesAfterEosGuess + 2;
}

/// A Pocket TTS voice: a reference recording the model imitates.
class PocketVoice implements Voice {
  PocketVoice(this.pack, this.name, this.wav);

  final PocketPack pack;
  final String name;

  /// Path of the reference WAV.
  final String wav;

  @override
  TtsModelKind get model => TtsModelKind.pocket;

  @override
  String get key => 'pocket:$language:$name';

  @override
  String get language => pack.language;

  @override
  bool? get female => _knownFemale[name];

  @override
  String get description =>
      '${name[0].toUpperCase()}${name.substring(1)} · ${language.toUpperCase()}';

  @override
  bool operator ==(Object other) => other is PocketVoice && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// Pocket TTS (Kyutai) packs installed in `<models>/pocket/<language>`,
/// one per language. Each language can be downloaded on demand from Hugging
/// Face ([downloadLanguage]) or installed from a local folder made with
/// `pocket_tts_export` ([installFrom]).
class PocketModel extends ChangeNotifier implements VoiceModel {
  PocketModel(
    Directory modelsDirectory, {
    this.baseUrl = defaultBaseUrl,
  }) : directory = Directory(p.join(modelsDirectory.path, 'pocket')) {
    _scan();
  }

  static const repoId = 'Duf-1/pocket-tts-sherpa-onnx';
  static const defaultBaseUrl =
      'https://huggingface.co/$repoId/resolve/main';
  static const approximateSizePerLanguage = '185 MB';

  /// Languages available for one-click download from [baseUrl].
  static List<String> get downloadableLanguages =>
      pocketRemoteArchives.keys.toList();

  final Directory directory;
  final String baseUrl;

  var _packs = <PocketPack>[];
  var _status = ModelStatus.missing;
  String? _downloadingLanguage;
  double? _progress;
  String? _error;
  HttpClient? _client;
  Future<PocketEngine>? _engine;

  List<PocketPack> get packs => _packs;
  ModelStatus get status => _status;

  /// Language code (`fr`, `en`…) currently being downloaded or extracted.
  String? get downloadingLanguage => _downloadingLanguage;

  /// Download progress in [0, 1], null if unknown.
  double? get progress => _progress;
  String? get error => _error;
  bool get isBusy =>
      _status == ModelStatus.downloading || _status == ModelStatus.extracting;

  @override
  TtsModelKind get kind => TtsModelKind.pocket;

  @override
  bool get isReady => _packs.isNotEmpty;

  @override
  bool get supportsSpeed => false;

  List<PocketVoice> get _voices => [for (final p in _packs) ...p.voices];

  @override
  List<Voice> voicesFor(String language) => [
    ..._voices.where((v) => v.language == language),
    ..._voices.where((v) => v.language != language),
  ];

  @override
  Voice defaultVoiceFor(String language) {
    final voices = voicesFor(language);
    if (voices.isEmpty) throw StateError('No Pocket TTS voice installed');
    if (voices.first.language == language) return voices.first;
    return _voices.where((v) => v.language == 'en').firstOrNull ?? voices.first;
  }

  @override
  Voice? voiceByKey(String key) =>
      _voices.where((v) => v.key == key).firstOrNull;

  bool supportsLanguage(String language) =>
      _packs.any((p) => p.language == language);

  void _scan() {
    final packs = <PocketPack>[];
    if (directory.existsSync()) {
      for (final d in directory.listSync().whereType<Directory>()) {
        if (d.path.endsWith('.part')) continue;
        final pack = PocketPack.load(d.path);
        if (pack != null) packs.add(pack);
      }
    }
    packs.sort((a, b) => a.languageName.compareTo(b.languageName));
    _packs = packs;
    if (!isBusy) _status = isReady ? ModelStatus.ready : ModelStatus.missing;
  }

  /// Copies the packs found in [folder] (a pack, or a folder of packs such
  /// as `pocket_tts_export/out`). A pack replaces the installed one of the
  /// same language. Returns the languages installed.
  Future<List<String>> installFrom(String folder) async {
    if (isBusy) return const [];
    final candidates = <PocketPack>[];
    final own = PocketPack.load(folder);
    if (own != null) {
      candidates.add(own);
    } else if (Directory(folder).existsSync()) {
      final dirs = Directory(folder).listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final d in dirs) {
        final pack = PocketPack.load(d.path);
        // One per language: the first folder in name order wins.
        if (pack != null &&
            !candidates.any((c) => c.language == pack.language)) {
          candidates.add(pack);
        }
      }
    }
    if (candidates.isEmpty) {
      _set(
        isReady ? ModelStatus.ready : ModelStatus.failed,
        error: 'No Pocket TTS model (pocket.json) found in $folder',
      );
      return const [];
    }
    _set(ModelStatus.extracting);
    try {
      await directory.create(recursive: true);
      await unload();
      for (final pack in candidates) {
        final target = p.join(directory.path, pack.language);
        final part = '$target.part';
        if (Directory(part).existsSync()) {
          await Directory(part).delete(recursive: true);
        }
        await _copyDirectory(Directory(pack.directory), Directory(part));
        if (Directory(target).existsSync()) {
          await Directory(target).delete(recursive: true);
        }
        await Directory(part).rename(target);
      }
      _status = ModelStatus.ready;
      _error = null;
      _scan();
      notifyListeners();
      return [for (final c in candidates) c.language];
    } catch (e) {
      _status = ModelStatus.failed;
      _scan();
      _set(isReady ? ModelStatus.ready : ModelStatus.failed, error: '$e');
      return const [];
    }
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final relative = p.relative(entity.path, from: source.path);
      final dstPath = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(dstPath).create(recursive: true);
      } else if (entity is File) {
        await File(dstPath).parent.create(recursive: true);
        await entity.copy(dstPath);
      }
    }
  }

  /// Downloads and installs the Pocket TTS pack for [language] (`en`, `fr`,
  /// `de`, `es`) from Hugging Face.
  Future<bool> downloadLanguage(String language) async {
    final archiveName = pocketRemoteArchives[language];
    if (archiveName == null) {
      _set(
        isReady ? ModelStatus.ready : ModelStatus.failed,
        error: 'No Pocket TTS download for "$language"',
      );
      return false;
    }
    if (isBusy) return false;
    _downloadingLanguage = language;
    _set(ModelStatus.downloading, progress: 0);
    final archive = File(p.join(directory.path, '$archiveName.part'));
    final staging = Directory(p.join(directory.path, '.extract_$language'));
    IOSink? sink;
    try {
      await directory.create(recursive: true);
      if (archive.existsSync()) archive.deleteSync();
      if (staging.existsSync()) await staging.delete(recursive: true);
      final url = '$baseUrl/$archiveName';
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
      await staging.create(recursive: true);
      final result = await Process.run('tar', [
        '-xjf',
        archive.path,
        '-C',
        staging.path,
      ]);
      if (result.exitCode != 0) {
        throw ProcessException('tar', [], '${result.stderr}');
      }
      _downloadingLanguage = null;
      _progress = null;
      _status = isReady ? ModelStatus.ready : ModelStatus.missing;
      final installed = await installFrom(staging.path);
      if (installed.isEmpty) {
        throw StateError('The archive does not contain a valid Pocket TTS pack');
      }
      return true;
    } catch (e) {
      _downloadingLanguage = null;
      _progress = null;
      if (_status != ModelStatus.missing) {
        _scan();
        _set(isReady ? ModelStatus.ready : ModelStatus.failed, error: '$e');
      }
      return false;
    } finally {
      await sink?.close().catchError((_) {});
      _client?.close(force: true);
      _client = null;
      if (archive.existsSync()) archive.deleteSync();
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  void cancelDownload() {
    if (_status != ModelStatus.downloading) return;
    _downloadingLanguage = null;
    _scan();
    _set(isReady ? ModelStatus.ready : ModelStatus.missing);
    _client?.close(force: true);
  }

  @override
  Future<PocketEngine> engine() {
    if (!isReady) {
      return Future.error(StateError('No Pocket TTS model installed'));
    }
    return _engine ??= PocketEngine.start().catchError((Object e) {
      _engine = null;
      throw e;
    });
  }

  /// Stops the engine to free its memory; [engine] starts it again.
  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    await engine?.then((e) => e.dispose(), onError: (_) {});
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
    unload();
    super.dispose();
  }
}

/// Pocket TTS running in a background isolate. One language model is loaded
/// at a time; voices of another language load theirs (about a second).
class PocketEngine implements Synthesizer {
  PocketEngine._(this._isolate, this._requests, this._responses);

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _responses;
  final _pending = <int, Completer<AudioClip>>{};
  var _nextId = 0;
  var _closed = false;

  /// [sherpaLibraryDir] locates the native library outside the app (tests).
  static Future<PocketEngine> start({
    int threads = 4,
    String? sherpaLibraryDir,
  }) async {
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(_main, (
      responses.sendPort,
      threads,
      sherpaLibraryDir,
    ), debugName: 'pocket-tts');
    final stream = responses.asBroadcastStream();
    final first = await stream.first;
    if (first is! SendPort) {
      responses.close();
      isolate.kill();
      throw StateError('Could not start the voice engine: $first');
    }
    final engine = PocketEngine._(isolate, first, responses);
    stream.listen(engine._onResponse);
    return engine;
  }

  /// Pocket TTS has no speed control: [speed] is ignored.
  @override
  Future<AudioClip> synthesize(String text, Voice voice, double speed) {
    if (_closed) return Future.error(StateError('Voice engine stopped'));
    if (voice is! PocketVoice) {
      return Future.error(ArgumentError.value(voice, 'voice', 'not Pocket'));
    }
    final pack = voice.pack;
    final prepared = preparePocketText(text, pack.rules);
    if (prepared == null) return Future.value(AudioClip(Float32List(0), 24000));
    final id = _nextId++;
    final completer = Completer<AudioClip>();
    _pending[id] = completer;
    _requests.send((
      id,
      prepared.text,
      pack.directory,
      pack.files,
      voice.wav,
      pack.framesAfterEos(prepared),
      pack.temperature,
    ));
    return completer.future;
  }

  void _onResponse(Object? message) {
    if (message case (int id, TransferableTypedData data, int sampleRate)) {
      final samples = data.materialize().asFloat32List();
      _pending.remove(id)?.complete(AudioClip(samples, sampleRate));
    } else if (message case (int id, String error)) {
      _pending.remove(id)?.completeError(StateError(error));
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _requests.send(null);
    _responses.close();
    for (final c in _pending.values) {
      c.completeError(StateError('Voice engine stopped'));
    }
    _pending.clear();
    Future<void>.delayed(const Duration(seconds: 2), _isolate.kill);
  }

  // ------------------------------------------------------------ isolate side

  static Future<void> _main((SendPort, int, String?) args) async {
    final (replies, threads, sherpaDir) = args;
    try {
      await sherpa.initBindingsAsync(sherpaDir);
    } catch (e) {
      replies.send('$e');
      return;
    }
    final requests = ReceivePort();
    replies.send(requests.sendPort);

    String? loadedDir;
    sherpa.OfflineTts? tts;
    final references = <String, AudioClip>{};

    await for (final message in requests) {
      if (message == null) break;
      final (
        id,
        text,
        dir,
        files,
        wav,
        framesAfterEos,
        temperature,
      ) = message
          as (int, String, String, Map<String, String>, String, int, double);
      try {
        if (loadedDir != dir || tts == null) {
          tts?.free();
          tts = null;
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                pocket: sherpa.OfflineTtsPocketModelConfig(
                  lmMain: files['lm_main']!,
                  lmFlow: files['lm_flow']!,
                  encoder: files['encoder']!,
                  decoder: files['decoder']!,
                  textConditioner: files['text_conditioner']!,
                  vocabJson: files['vocab_json']!,
                  tokenScoresJson: files['token_scores_json']!,
                ),
                numThreads: threads,
              ),
            ),
          );
          loadedDir = dir;
        }
        final reference = references[wav] ??= AudioClip.fromWav(
          File(wav).readAsBytesSync(),
        );
        final audio = tts.generateWithConfig(
          text: text,
          config: sherpa.OfflineTtsGenerationConfig(
            // sherpa's default (0.2) shortens the pauses the model makes.
            silenceScale: 1.0,
            referenceAudio: reference.samples,
            referenceSampleRate: reference.sampleRate,
            numSteps: 1,
            extra: {
              'temperature': temperature,
              'frames_after_eos': framesAfterEos,
              // The app sends one sentence at a time: no splitting.
              'min_char_in_sentence': 100000,
              'max_char_in_sentence': 100000,
            },
          ),
        );
        replies.send((
          id,
          TransferableTypedData.fromList([audio.samples]),
          audio.sampleRate,
        ));
      } catch (e) {
        replies.send((id, '$e'));
      }
    }
    tts?.free();
    requests.close();
  }
}
