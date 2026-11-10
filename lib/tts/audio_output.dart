import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;

import 'audio_clip.dart';

/// Plays one clip at a time.
abstract interface class AudioOutput {
  /// Plays [clip]; completes when it has finished or was stopped.
  Future<void> play(AudioClip clip);
  Future<void> pause();
  Future<void> resume();

  /// Stops playback; the pending [play] completes.
  Future<void> stop();
  void dispose();
}

/// [AudioOutput] backed by audioplayers: each clip is written to a temporary
/// WAV file and played from there.
class PlayerAudioOutput implements AudioOutput {
  PlayerAudioOutput() {
    // With the default ReleaseMode.release, the macOS plugin releases the
    // player asynchronously after reporting completion; when the next clip's
    // setSource is already running by then, that release drops the new item
    // and its preparation never finishes ("leaked its continuation"), which
    // stalls reading. In stop mode it only seeks the finished item back to 0.
    _player.setReleaseMode(ReleaseMode.stop);
    _complete = _player.onPlayerComplete.listen((_) => _onComplete());
  }

  final _player = AudioPlayer(playerId: 'read-aloud');
  late final StreamSubscription<void> _complete;
  Completer<void>? _playing;
  Directory? _dir;
  var _counter = 0;

  Future<File> _write(AudioClip clip) async {
    final dir = _dir ??= await Directory.systemTemp.createTemp(
      'epub_reader_tts',
    );
    // A new file per clip: when sentences are skipped quickly, the player
    // may still be opening the previous ones. Old ones are deleted.
    final n = _counter++;
    final old = File(p.join(dir.path, 'clip${n - 4}.wav'));
    if (n >= 4) old.delete().ignore();
    final file = File(p.join(dir.path, 'clip$n.wav'));
    await file.writeAsBytes(clip.toWav(), flush: true);
    return file;
  }

  @override
  Future<void> play(AudioClip clip) async {
    _finish();
    if (clip.isEmpty) return;
    final done = _playing = Completer<void>();
    final file = await _write(clip);
    if (done.isCompleted) return; // stopped meanwhile
    // Not awaited: when a newer clip or stop() replaces this one while the
    // player is still preparing it, audioplayers never reports it prepared
    // and fails 30 s later. Only an error of the current clip matters.
    _player.play(DeviceFileSource(file.path, mimeType: 'audio/wav')).catchError(
      (Object e, StackTrace stack) {
        if (!identical(_playing, done)) return;
        _playing = null;
        done.completeError(e, stack);
      },
    );
    return done.future;
  }

  /// The plugin reports completion before seeking the finished item back to
  /// 0. Starting the next clip during that seek would seek the new item while
  /// it is still preparing, so wait for the seek (with a fallback).
  void _onComplete() {
    final done = _playing;
    if (done == null) return;
    _player.onSeekComplete.first
        .timeout(const Duration(milliseconds: 500))
        .catchError((_) {})
        .whenComplete(() {
          if (identical(_playing, done)) _finish();
        });
  }

  void _finish() {
    final c = _playing;
    _playing = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() async {
    _finish();
    await _player.stop();
  }

  @override
  void dispose() {
    _finish();
    _complete.cancel();
    _player.dispose();
    final dir = _dir;
    if (dir != null) dir.delete(recursive: true).ignore();
  }
}
