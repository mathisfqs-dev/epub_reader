@Tags(['model'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/kokoro_voices.dart';
import 'package:epub_reader/tts/tts_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Runs the real Kokoro model if it is installed in the app's support
/// directory (it is downloaded by the app on first use).
void main() {
  final models = Directory(
    p.join(
      Platform.environment['HOME'] ?? '',
      'Library/Application Support/com.example.epubReader/models',
    ),
  );
  final model = KokoroModel(models);

  // `flutter test` does not link the plugins' native libraries into the
  // process: load them from the pub cache.
  String packageDir(String name) {
    final config = File('.dart_tool/package_config.json');
    final packages = (jsonDecode(config.readAsStringSync())['packages'] as List)
        .cast<Map<String, dynamic>>();
    final root = packages.firstWhere((p) => p['name'] == name)['rootUri'];
    return config.absolute.uri.resolve('$root').toFilePath();
  }

  test('synthesizes English and French', () async {
    final engine = await TtsEngine.start(
      model.files,
      sherpaLibraryDir: p.join(packageDir('sherpa_onnx_macos'), 'macos'),
      piperLibraryDir: p.join(packageDir('piper_phonemize'), 'macos'),
    );
    addTearDown(engine.dispose);
    final en = await engine.synthesize(
      'Alice was beginning to get very tired.',
      voiceNamed('af_heart')!,
      1.0,
    );
    expect(en.sampleRate, 24000);
    expect(en.duration.inMilliseconds, inInclusiveRange(1000, 5000));

    final fr = await engine.synthesize(
      'Candide fut chassé du château.',
      voiceNamed('ff_siwis')!,
      1.0,
    );
    expect(fr.duration.inMilliseconds, inInclusiveRange(800, 5000));

    final faster = await engine.synthesize(
      'Alice was beginning to get very tired.',
      voiceNamed('af_heart')!,
      1.5,
    );
    expect(faster.duration, lessThan(en.duration));

    final silent = await engine.synthesize('...', voiceNamed('af_heart')!, 1);
    expect(silent.isEmpty, isTrue);
  }, skip: model.isReady ? false : 'Kokoro model not installed');
}
