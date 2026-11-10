// Smoke test of translation inside the real macOS app (llama-server started
// as a child process of the app):
//   flutter run -d macos -t test_driver/translate_smoke.dart
import 'dart:io';

import 'package:epub_reader/translate/llama_server.dart';
import 'package:epub_reader/translate/translation_model.dart';
import 'package:epub_reader/translate/translator.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final model = LlamaTranslationModel(Directory(p.join(support.path, 'models')));
  debugPrint('SMOKE model ready: ${model.isReady}');
  debugPrint('SMOKE llama-server: ${LlamaServer.find()}');
  try {
    final sw = Stopwatch()..start();
    final translator = await model.translator();
    debugPrint('SMOKE server started in ${sw.elapsedMilliseconds} ms');
    for (final (text, source, target) in [
      ('Aujourd’hui, maman est morte.', 'fr', 'en'),
      ('Alice was beginning to get very tired.', 'en', 'fr'),
    ]) {
      sw.reset();
      var first = -1;
      final out = StringBuffer();
      await for (final piece in translator.translate(
        TranslationRequest(text: text, source: source, target: target),
      )) {
        if (first < 0) first = sw.elapsedMilliseconds;
        out.write(piece);
      }
      debugPrint(
        'SMOKE $source→$target first words after $first ms, done in '
        '${sw.elapsedMilliseconds} ms: ${out.toString().trim()}',
      );
    }
    await model.unload();
    final left = await Process.run('pgrep', ['-x', 'llama-server']);
    debugPrint('SMOKE server stopped: ${'${left.stdout}'.trim().isEmpty}');
    debugPrint('SMOKE OK');
  } catch (e, st) {
    debugPrint('SMOKE FAILED $e\n$st');
  }
  exit(0);
}
