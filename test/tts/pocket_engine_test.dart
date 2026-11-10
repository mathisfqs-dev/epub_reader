@Tags(['model'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:epub_reader/tts/pocket_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Runs the real Pocket TTS packs installed in the app's support directory.
void main() {
  final model = PocketModel(
    Directory(
      p.join(
        Platform.environment['HOME'] ?? '',
        'Library/Application Support/com.example.epubReader/models',
      ),
    ),
  );

  String packageDir(String name) {
    final config = File('.dart_tool/package_config.json');
    final packages = (jsonDecode(config.readAsStringSync())['packages'] as List)
        .cast<Map<String, dynamic>>();
    final root = packages.firstWhere((p) => p['name'] == name)['rootUri'];
    return config.absolute.uri.resolve('$root').toFilePath();
  }

  test('synthesizes every installed language', () async {
    if (!model.isReady) {
      markTestSkipped('No Pocket TTS pack installed');
      return;
    }
    final engine = await PocketEngine.start(
      sherpaLibraryDir: p.join(packageDir('sherpa_onnx_macos'), 'macos'),
    );
    addTearDown(engine.dispose);
    const texts = {
      'fr': "« Aujourd'hui, maman est morte ; ou peut-être hier. »",
      'en': 'Alice was beginning to get very tired of sitting by her sister.',
      'de': 'Als Gregor Samsa eines Morgens erwachte, war er verwandelt.',
      'es': '¿En un lugar de la Mancha? ¡Sí!',
    };
    for (final pack in model.packs) {
      final text = texts[pack.language] ?? 'Hello.';
      final watch = Stopwatch()..start();
      final clip = await engine.synthesize(text, pack.voices.first, 1);
      final seconds = clip.duration.inMilliseconds / 1000;
      // ignore: avoid_print
      print(
        '${pack.language} ${pack.voices.first.name}: ${seconds}s of audio '
        'in ${watch.elapsedMilliseconds} ms',
      );
      // POCKET_TEST_OUT=dir keeps the audio for pocket_tts_export/asr_check.py.
      final out = Platform.environment['POCKET_TEST_OUT'];
      if (out != null) {
        final dir = Directory(p.join(out, pack.language))
          ..createSync(recursive: true);
        File(p.join(dir.path, '0_sherpa_t0.3.wav'))
            .writeAsBytesSync(clip.toWav());
        File(p.join(dir.path, '0_text.txt')).writeAsStringSync(text);
      }
      expect(clip.sampleRate, 24000);
      expect(seconds, inInclusiveRange(1.0, 15.0));
      final peak = clip.samples.fold(0.0, (m, s) => s.abs() > m ? s.abs() : m);
      expect(peak, greaterThan(0.05));
    }
    expect(
      (await engine.synthesize(
        '« »',
        model.packs.first.voices.first,
        1,
      )).isEmpty,
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
