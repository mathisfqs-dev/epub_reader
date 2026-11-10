import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:piper_phonemize/piper_phonemize.dart' as piper;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_clip.dart';
import 'kokoro_voices.dart';
import 'voice.dart';

/// Turns text into audio.
abstract interface class Synthesizer {
  Future<AudioClip> synthesize(String text, Voice voice, double speed);
}

/// Files of an installed Kokoro model.
class KokoroFiles {
  const KokoroFiles(this.directory);

  final String directory;

  String get model => '$directory/model.onnx';
  String get voices => '$directory/voices.bin';
  String get tokens => '$directory/tokens.txt';
  String get espeakData => '$directory/espeak-ng-data';

  List<String> get required => [model, voices, tokens, '$espeakData/phontab'];
}

/// Kokoro text-to-speech running in a long-lived background isolate, so
/// synthesis (a blocking native call) never freezes the UI.
///
/// Text is phonemized with eSpeak-NG (piper_phonemize) and spoken by Kokoro
/// through sherpa-onnx.
class TtsEngine implements Synthesizer {
  TtsEngine._(this._isolate, this._requests, this._responses);

  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _responses;
  final _pending = <int, Completer<AudioClip>>{};
  var _nextId = 0;
  var _closed = false;

  /// Starts the isolate and loads the model (takes about a second).
  ///
  /// In the app the native libraries are linked into the process;
  /// [sherpaLibraryDir] and [piperLibraryDir] locate them elsewhere (tests).
  static Future<TtsEngine> start(
    KokoroFiles files, {
    int threads = 4,
    String? sherpaLibraryDir,
    String? piperLibraryDir,
  }) async {
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(_main, (
      responses.sendPort,
      files.directory,
      threads,
      sherpaLibraryDir,
      piperLibraryDir,
    ), debugName: 'kokoro-tts');
    final stream = responses.asBroadcastStream();
    final first = await stream.first;
    if (first is! SendPort) {
      responses.close();
      isolate.kill();
      throw StateError('Could not start the voice engine: $first');
    }
    final engine = TtsEngine._(isolate, first, responses);
    stream.listen(engine._onResponse);
    return engine;
  }

  @override
  Future<AudioClip> synthesize(String text, Voice voice, double speed) {
    if (_closed) return Future.error(StateError('Voice engine stopped'));
    if (voice is! KokoroVoice) {
      return Future.error(ArgumentError.value(voice, 'voice', 'not Kokoro'));
    }
    final id = _nextId++;
    final completer = Completer<AudioClip>();
    _pending[id] = completer;
    _requests.send((id, text, voice.id, voice.espeakVoice, speed));
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

  static Future<void> _main(
    (SendPort, String, int, String?, String?) args,
  ) async {
    final (replies, directory, threads, sherpaDir, piperDir) = args;
    final files = KokoroFiles(directory);
    final sherpa.OfflineTts tts;
    try {
      await sherpa.initBindingsAsync(sherpaDir);
      await piper.initBindingsAsync(piperDir);
      if (piper.PiperPhonemize.initialize(files.espeakData) < 0) {
        throw StateError('eSpeak data not found in ${files.espeakData}');
      }
      tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(
          model: sherpa.OfflineTtsModelConfig(
            kokoro: sherpa.OfflineTtsKokoroModelConfig(
              model: files.model,
              voices: files.voices,
              tokens: files.tokens,
            ),
            numThreads: threads,
          ),
        ),
      );
    } catch (e) {
      replies.send('$e');
      return;
    }

    final requests = ReceivePort();
    replies.send(requests.sendPort);
    await for (final message in requests) {
      if (message == null) break;
      final (id, text, sid, espeakVoice, speed) =
          message as (int, String, int, String, double);
      try {
        final phonemes = piper.PiperPhonemize.phonemize(
          text,
          voice: espeakVoice,
        ).where((s) => s.isNotEmpty).toList();
        if (phonemes.isEmpty) {
          replies.send((
            id,
            TransferableTypedData.fromList([Float32List(0)]),
            tts.sampleRate,
          ));
          continue;
        }
        final audio = tts.generateWithConfig(
          text: '',
          config: sherpa.OfflineTtsGenerationConfig(
            sid: sid,
            speed: speed,
            phonemeCodepoints: phonemes,
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
    tts.free();
    requests.close();
  }
}
