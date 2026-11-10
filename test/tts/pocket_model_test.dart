import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:epub_reader/app/reader_settings.dart';
import 'package:epub_reader/tts/audio_clip.dart';
import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/pocket_model.dart';
import 'package:epub_reader/tts/speech_models.dart';
import 'package:epub_reader/tts/voice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Writes a pack like pack_sherpa.py does, with empty model files.
Directory fakePack(
  Directory parent,
  String name,
  String language,
  List<String> voices,
) {
  final dir = Directory(p.join(parent.path, name))..createSync(recursive: true);
  const files = {
    'lm_main': 'lm_main.int8.onnx',
    'lm_flow': 'lm_flow.int8.onnx',
    'decoder': 'decoder.onnx',
    'encoder': 'encoder.onnx',
    'text_conditioner': 'text_conditioner.onnx',
    'vocab_json': 'vocab.json',
    'token_scores_json': 'token_scores.json',
  };
  for (final f in files.values) {
    File(p.join(dir.path, f)).createSync();
  }
  final clip = AudioClip(Float32List(240), 24000);
  for (final v in voices) {
    File(p.join(dir.path, 'voices', '$v.wav'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(clip.toWav());
  }
  File(p.join(dir.path, 'pocket.json')).writeAsStringSync(
    jsonEncode({
      'language': language,
      'files': files,
      'text': {'remove_semicolons': true},
      'model_recommended_frames_after_eos': null,
      'default_temperature': 0.3,
      'voices': {for (final v in voices) v: 'voices/$v.wav'},
    }),
  );
  return dir;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('pocket'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads a pack', () {
    final dir = fakePack(tmp, 'pocket-french-int8', 'french', [
      'estelle',
      'fabien',
    ]);
    final pack = PocketPack.load(dir.path)!;
    expect(pack.language, 'fr');
    expect(pack.languageName, 'Français');
    expect(pack.temperature, 0.3);
    expect(pack.rules.removeSemicolons, isTrue);
    expect(pack.files['lm_main'], p.join(dir.path, 'lm_main.int8.onnx'));
    expect(pack.voices.map((v) => v.description), [
      'Estelle · FR',
      'Fabien · FR',
    ]);
    expect(pack.voices.first.female, isTrue);
    expect(pack.voices.last.female, isFalse);
    expect(pack.voices.first.key, 'pocket:fr:estelle');
    // Upstream's rule: the guess + 2 when the model has no recommendation.
    expect(pack.framesAfterEos((text: 'Oui.', framesAfterEosGuess: 3)), 5);
  });

  test('an incomplete pack is ignored', () {
    final dir = fakePack(tmp, 'pack', 'german', ['juergen']);
    File(p.join(dir.path, 'decoder.onnx')).deleteSync();
    expect(PocketPack.load(dir.path), isNull);
    expect(PocketPack.load(tmp.path), isNull);
  });

  test('installs packs from a folder, one per language', () async {
    final out = Directory(p.join(tmp.path, 'out'));
    fakePack(out, 'pocket-french-int8', 'french', ['estelle']);
    fakePack(out, 'pocket-french_24l-int8', 'french_24l', ['fabien']);
    fakePack(out, 'pocket-german-int8', 'german', ['juergen']);
    Directory(p.join(out.path, 'validate')).createSync();

    final model = PocketModel(Directory(p.join(tmp.path, 'models')));
    expect(model.isReady, isFalse);
    expect(model.status, ModelStatus.missing);

    expect(await model.installFrom(out.path), ['fr', 'de']);
    expect(model.isReady, isTrue);
    expect(model.packs.map((p) => p.language), ['de', 'fr']);
    expect(
      Directory(p.join(tmp.path, 'models', 'pocket', 'fr')).existsSync(),
      isTrue,
    );
    // The 6-layer French pack comes first in name order.
    expect(model.voicesFor('fr').first.key, 'pocket:fr:estelle');
    expect(model.defaultVoiceFor('de').key, 'pocket:de:juergen');
    expect(model.voiceByKey('pocket:de:juergen'), isA<PocketVoice>());

    // A new model object finds them on disk.
    final again = PocketModel(Directory(p.join(tmp.path, 'models')));
    expect(again.packs.length, 2);

    // A single pack replaces the installed one of its language.
    final newer = fakePack(tmp, 'new-fr', 'french', ['estelle', 'fabien']);
    expect(await model.installFrom(newer.path), ['fr']);
    expect(model.voicesFor('fr').take(2).map((v) => v.key), [
      'pocket:fr:estelle',
      'pocket:fr:fabien',
    ]);
  });

  test('a folder without packs is an error', () async {
    final model = PocketModel(Directory(p.join(tmp.path, 'models')));
    expect(await model.installFrom(tmp.path), isEmpty);
    expect(model.error, contains('No Pocket TTS model'));
    expect(model.isReady, isFalse);
  });

  test('reads float and 16-bit WAV files', () {
    final clip = AudioClip(Float32List.fromList([0, 0.5, -0.5, 1]), 24000);
    final pcm = AudioClip.fromWav(clip.toWav());
    expect(pcm.sampleRate, 24000);
    expect(pcm.samples[1], closeTo(0.5, 1e-4));
    expect(pcm.samples[2], closeTo(-0.5, 1e-4));

    // 32-bit float, as soundfile writes the voices.
    final b = BytesBuilder();
    final header = ByteData(44);
    void ascii(int at, String s) {
      for (var i = 0; i < 4; i++) {
        header.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + 8, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 3, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 64000, Endian.little);
    header.setUint16(32, 4, Endian.little);
    header.setUint16(34, 32, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, 8, Endian.little);
    b.add(header.buffer.asUint8List());
    b.add(Float32List.fromList([0.25, -0.75]).buffer.asUint8List());
    final float = AudioClip.fromWav(b.toBytes());
    expect(float.sampleRate, 16000);
    expect(float.samples, [0.25, -0.75]);

    expect(
      () => AudioClip.fromWav(Uint8List(8)),
      throwsA(isA<FormatException>()),
    );
  });

  test('the chosen model and voices are saved in the settings', () async {
    final models = Directory(p.join(tmp.path, 'models'));
    final pocket = PocketModel(models);
    await pocket.installFrom(
      fakePack(tmp, 'p', 'french', ['estelle', 'fabien']).path,
    );
    final settings = ReaderSettings.memory();
    final speech = SpeechModels(
      settings: settings,
      kokoro: KokoroModel(models),
      pocket: pocket,
    );
    expect(speech.activeKind, TtsModelKind.kokoro);
    expect(speech.voiceFor('fr').key, 'ff_siwis');

    speech.select(TtsModelKind.pocket);
    expect(settings.ttsModel, TtsModelKind.pocket);
    expect(speech.active, same(pocket));
    expect(speech.voiceFor('fr').key, 'pocket:fr:estelle');

    settings.setVoice('fr', pocket.voiceByKey('pocket:fr:fabien')!);
    expect(speech.voiceFor('fr').key, 'pocket:fr:fabien');
    // Kokoro's choice is kept apart.
    expect(settings.voiceFor('fr').name, 'ff_siwis');
  });

  test('trims the silence around speech, keeps a margin', () {
    // 100 ms silence, 100 ms of sound, 300 ms silence at 1 kHz.
    final samples = Float32List(500);
    for (var i = 100; i < 200; i++) {
      samples[i] = i.isEven ? 0.5 : -0.5;
    }
    final trimmed = AudioClip(samples, 1000).trimSilence();
    expect(trimmed.samples.length, 40 + 100 + 40);
    expect(trimmed.samples[40], 0.5);
    // Pure silence is left alone.
    final silent = AudioClip(Float32List(50), 1000);
    expect(silent.trimSilence(), same(silent));
  });
}
