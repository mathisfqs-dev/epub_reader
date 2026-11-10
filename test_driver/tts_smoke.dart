// Smoke test of read-aloud inside the real macOS app (native libraries
// linked by CocoaPods): flutter run -d macos -t test_driver/tts_smoke.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:epub_reader/tts/audio_clip.dart';
import 'package:epub_reader/tts/audio_output.dart';
import 'package:epub_reader/tts/kokoro_model.dart';
import 'package:epub_reader/tts/kokoro_voices.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final model = KokoroModel(Directory(p.join(support.path, 'models')));
  debugPrint('SMOKE model ready: ${model.isReady}');
  try {
    final sw = Stopwatch()..start();
    final engine = await model.engine();
    debugPrint('SMOKE engine started in ${sw.elapsedMilliseconds} ms');
    sw.reset();
    final clip = await engine.synthesize(
      'It was the best of times.',
      voiceNamed('af_heart')!,
      1.0,
    );
    debugPrint(
      'SMOKE synthesized ${clip.duration.inMilliseconds} ms of audio '
      'in ${sw.elapsedMilliseconds} ms',
    );
    final output = PlayerAudioOutput();
    for (var i = 0; i < 3; i++) {
      sw.reset();
      await output
          .play(AudioClip(Float32List(24000 ~/ 3), 24000))
          .timeout(const Duration(seconds: 8));
      debugPrint(
        'SMOKE silent 333 ms clip #$i completed in ${sw.elapsedMilliseconds} ms',
      );
    }
    output.dispose();
    engine.dispose();
    debugPrint('SMOKE OK');
  } catch (e, st) {
    debugPrint('SMOKE FAILED $e\n$st');
  }
  exit(0);
}
