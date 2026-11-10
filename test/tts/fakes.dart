import 'dart:async';
import 'dart:typed_data';

import 'package:epub_reader/tts/audio_clip.dart';
import 'package:epub_reader/tts/audio_output.dart';
import 'package:epub_reader/tts/voice.dart';
import 'package:epub_reader/tts/tts_engine.dart';

/// Returns one sample per character of text.
class FakeSynthesizer implements Synthesizer {
  final requests = <(String, Voice, double)>[];
  Object? failWith;

  @override
  Future<AudioClip> synthesize(String text, Voice voice, double speed) {
    requests.add((text, voice, speed));
    if (failWith != null) return Future.error(failWith!);
    return Future.value(AudioClip(Float32List(text.length), 24000));
  }
}

/// Playback that only ends when the test calls [finish].
class FakeOutput implements AudioOutput {
  final played = <AudioClip>[];
  final calls = <String>[];
  Object? failWith;
  Completer<void>? _current;
  var disposed = false;

  bool get isPlaying => _current != null;

  void finish() {
    final c = _current;
    _current = null;
    c?.complete();
  }

  @override
  Future<void> play(AudioClip clip) {
    played.add(clip);
    calls.add('play');
    if (failWith != null) return Future.error(failWith!);
    if (clip.isEmpty) return Future.value();
    return (_current = Completer<void>()).future;
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> stop() async {
    calls.add('stop');
    finish();
  }

  @override
  void dispose() => disposed = true;
}
