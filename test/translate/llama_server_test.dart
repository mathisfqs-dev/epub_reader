@Tags(['model'])
library;

import 'dart:io';

import 'package:epub_reader/translate/llama_server.dart';
import 'package:epub_reader/translate/translation_model.dart';
import 'package:epub_reader/translate/translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Runs the real model with llama-server if both are installed (the model is
/// downloaded by the app; llama-server comes from `brew install llama.cpp`).
void main() {
  final models = Directory(
    p.join(
      Platform.environment['HOME'] ?? '',
      'Library/Application Support/com.example.epubReader/models',
    ),
  );
  final model = File(
    p.join(models.path, 'llm', LlamaTranslationModel.fileName),
  );
  final binary = LlamaServer.find();
  final skip = binary == null
      ? 'llama-server not installed'
      : !model.existsSync()
      ? 'translation model not installed'
      : null;

  test(
    'translates French into English, streaming',
    () async {
      final dir = Directory.systemTemp.createTempSync('llama');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pidFile = File(p.join(dir.path, 'server.pid'));
      final watch = Stopwatch()..start();
      final server = await LlamaServer.start(
        binary: binary!,
        model: model.path,
        pidFile: pidFile,
        logFile: File(p.join(dir.path, 'server.log')),
      );
      addTearDown(server.stop);
      final loaded = watch.elapsed;
      expect(pidFile.readAsStringSync(), '${server.pid}');

      final translator = OpenAiChatTranslator(
        baseUri: server.baseUri,
        apiKey: server.apiKey,
      );
      watch.reset();
      final pieces = await translator
          .translate(
            const TranslationRequest(
              text:
                  'Aujourd’hui, maman est morte. Ou peut-être hier, je ne '
                  'sais pas.',
              source: 'fr',
              target: 'en',
              context:
                  'Aujourd’hui, maman est morte. Ou peut-être hier, je ne '
                  'sais pas. J’ai reçu un télégramme de l’asile.',
            ),
          )
          .toList();
      final text = pieces.join().trim();
      // ignore: avoid_print
      print(
        'loaded in ${loaded.inMilliseconds} ms, translated in '
        '${watch.elapsedMilliseconds} ms (${pieces.length} pieces): $text',
      );
      expect(pieces.length, greaterThan(3)); // streamed, not in one piece
      expect(text.toLowerCase(), contains('today'));
      expect(text.toLowerCase(), contains('yesterday'));
      expect(text.toLowerCase(), isNot(contains('telegram'))); // context only

      // Without the key the server refuses.
      final open = OpenAiChatTranslator(baseUri: server.baseUri);
      await expectLater(
        open
            .translate(
              const TranslationRequest(text: 'x', source: 'fr', target: 'en'),
            )
            .toList(),
        throwsA(isA<TranslationException>()),
      );

      await server.stop();
      expect(server.isRunning, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pidFile.existsSync(), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('stops a server left behind by a crash', () async {
    final dir = Directory.systemTemp.createTempSync('llama');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pidFile = File(p.join(dir.path, 'server.pid'));
    // A "crashed app" left this server running.
    final orphan = await Process.start(binary!, [
      '--model',
      model.path,
      '--port',
      '0',
      '--no-webui',
    ]);
    pidFile.writeAsStringSync('${orphan.pid}');
    await LlamaServer.stopStale(pidFile);
    expect(
      await orphan.exitCode.timeout(const Duration(seconds: 10)),
      isNot(0),
    );
    expect(pidFile.existsSync(), isFalse);
  }, skip: skip);
}
