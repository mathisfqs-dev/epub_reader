import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:epub_reader/translate/languages.dart';
import 'package:epub_reader/translate/llama_server.dart';
import 'package:epub_reader/translate/translation_model.dart';
import 'package:epub_reader/translate/translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TranslationRequest.messages', () {
    test('names both languages and sends the paragraph as context', () {
      const r = TranslationRequest(
        text: ' Il est mort. ',
        source: 'fr',
        target: 'en',
        context: 'Hier, il pleuvait. Il est mort. On ne sait pas.',
      );
      final m = r.messages();
      expect(m.map((x) => x['role']), ['system', 'user']);
      expect(m[0]['content'], contains('from French into English'));
      expect(m[0]['content'], contains('Translate ONLY the passage'));
      expect(
        m[1]['content'],
        '<context>\nHier, il pleuvait. Il est mort. On ne sait pas.\n'
        '</context>\n\n<passage>\nIl est mort.\n</passage>\n\n'
        'Translate only this passage into English: «Il est mort.»',
      );
    });

    test('long passages are sent without context', () {
      final r = TranslationRequest(
        text: 'Word. ' * 300,
        source: 'en',
        target: 'fr',
        context: 'Before. ${'Word. ' * 300}After.',
      );
      expect(r.messages()[1]['content'], isNot(contains('<context>')));
    });

    test('sends the passage alone when the context adds nothing', () {
      const r = TranslationRequest(
        text: 'Whole paragraph.',
        source: 'en',
        target: 'de',
        context: 'Whole paragraph.',
      );
      expect(
        r.messages()[1]['content'],
        '<passage>\nWhole paragraph.\n</passage>',
      );
      expect(r.messages()[0]['content'], contains('into German'));
    });
  });

  test('default targets: French books into English, others into French', () {
    expect(TranslationLanguage.defaultTargetFor('fr'), 'en');
    expect(TranslationLanguage.defaultTargetFor('en'), 'fr');
    expect(TranslationLanguage.defaultTargetFor('de'), 'fr');
    expect(TranslationLanguage.of('xx').name, 'xx');
  });

  group('parseSseLine', () {
    test('reads deltas, the end, and errors', () {
      expect(
        (parseSseLine(
          'data: {"choices":[{"delta":{"content":"Hi"}}]}',
        ) as SseDelta).text,
        'Hi',
      );
      expect(parseSseLine('data: [DONE]'), isA<SseDone>());
      expect(
        (parseSseLine(
          'data: {"error":{"message":"boom"}}',
        ) as SseError).message,
        'boom',
      );
    });

    test('ignores blank lines, comments, and chunks without text', () {
      expect(parseSseLine(''), isNull);
      expect(parseSseLine(': keep-alive'), isNull);
      expect(
        parseSseLine(
          'data: {"choices":[{"delta":{"role":"assistant","content":null}}]}',
        ),
        isNull,
      );
      expect(parseSseLine('data: {not json'), isNull);
    });
  });

  group('OpenAiChatTranslator', () {
    late HttpServer server;
    late Future<void> Function(HttpRequest) handler;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) => handler(r));
    });
    tearDown(() => server.close(force: true));

    OpenAiChatTranslator translator() => OpenAiChatTranslator(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      apiKey: 'secret',
    );

    const request = TranslationRequest(
      text: 'Bonjour.',
      source: 'fr',
      target: 'en',
    );

    String chunk(String text) =>
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': text},
            },
          ],
        })}\n\n';

    test('streams the pieces, with the key and a streamed request', () async {
      Map<String, dynamic>? body;
      String? auth;
      handler = (r) async {
        auth = r.headers.value(HttpHeaders.authorizationHeader);
        body = jsonDecode(await utf8.decodeStream(r)) as Map<String, dynamic>;
        r.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        r.response.write(
          'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
        );
        for (final p in ['Hel', 'lo', ' – ça va.']) {
          r.response.write(chunk(p));
          await r.response.flush();
        }
        r.response.write('data: [DONE]\n\n');
        await r.response.close();
      };
      final pieces = await translator().translate(request).toList();
      expect(pieces, ['Hel', 'lo', ' – ça va.']);
      expect(auth, 'Bearer secret');
      expect(body!['stream'], isTrue);
      expect((body!['messages'] as List).last['content'], contains('Bonjour.'));
    });

    test('reports HTTP errors with the server message', () async {
      handler = (r) async {
        await r.drain<void>();
        r.response.statusCode = 401;
        r.response.write('{"error":{"message":"Invalid API Key"}}');
        await r.response.close();
      };
      await expectLater(
        translator().translate(request).toList(),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('401'), contains('Invalid API Key')),
          ),
        ),
      );
    });

    test('reports an unreachable server', () async {
      final port = server.port;
      await server.close(force: true);
      final t = OpenAiChatTranslator(
        baseUri: Uri.parse('http://127.0.0.1:$port'),
      );
      await expectLater(
        t.translate(request).toList(),
        throwsA(isA<TranslationException>()),
      );
    });

    test('cancelling closes the connection', () async {
      final closed = Completer<void>();
      handler = (r) async {
        await r.drain<void>();
        r.response.bufferOutput = false; // stream like llama-server
        r.response.done.whenComplete(() {
          if (!closed.isCompleted) closed.complete();
        }).ignore();
        // Keep streaming until the client goes away.
        for (var i = 0; i < 300 && !closed.isCompleted; i++) {
          r.response.write(chunk(i == 0 ? 'one' : ' more'));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      };
      final pieces = <String>[];
      final first = Completer<void>();
      final sub = translator().translate(request).listen((p) {
        pieces.add(p);
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await sub.cancel();
      // The server sees the connection close well before its 3 s of chunks.
      await closed.future.timeout(const Duration(seconds: 2));
      expect(pieces.first, 'one');
    });
  });

  group('LlamaTranslationModel download', () {
    late HttpServer server;
    late Directory temp;
    late Directory modelsDir;
    var serverDownloads = 0;
    var modelDownloads = 0;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('llama_model_test');
      modelsDir = Directory('${temp.path}/models');
      serverDownloads = 0;
      modelDownloads = 0;

      // Create a tar.gz archive containing a nested llama-b11429/llama-server
      // and a fake dylib.
      final archiveSrc = Directory('${temp.path}/archive_src/llama-b11429')
        ..createSync(recursive: true);
      File('${archiveSrc.path}/llama-server').writeAsStringSync('#!/bin/sh\n');
      File('${archiveSrc.path}/libllama.dylib').writeAsStringSync('dylib');
      final tarFile = File('${temp.path}/llama.tar.gz');
      final tarRes = await Process.run('tar', [
        '-czf',
        tarFile.path,
        '-C',
        '${temp.path}/archive_src',
        'llama-b11429',
      ]);
      expect(tarRes.exitCode, 0);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/llama.tar.gz') {
          serverDownloads++;
          final bytes = tarFile.readAsBytesSync();
          req.response.contentLength = bytes.length;
          req.response.add(bytes);
          await req.response.close();
        } else if (req.uri.path == '/model.gguf') {
          modelDownloads++;
          final bytes = utf8.encode('fake-gguf-weights');
          req.response.contentLength = bytes.length;
          req.response.add(bytes);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test(
      'skips downloading llama-server when one is already installed',
      () async {
        final existing = File('${temp.path}/existing-llama-server')
          ..writeAsStringSync('#!/bin/sh\n');
        final model = LlamaTranslationModel(
          modelsDir,
          modelUrl: 'http://127.0.0.1:${server.port}/model.gguf',
          serverArchiveUrl: 'http://127.0.0.1:${server.port}/llama.tar.gz',
          findServer: () => existing.path,
        );
        expect(model.isReady, isFalse);

        await model.download();

        expect(model.isReady, isTrue);
        expect(serverDownloads, 0);
        expect(modelDownloads, 1);
        expect(
          File(
            '${modelsDir.path}/llm/${LlamaTranslationModel.fileName}',
          ).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'downloads and extracts llama-server into bin/ when missing',
      () async {
        final binServer = File('${temp.path}/bin/llama-server');
        final model = LlamaTranslationModel(
          modelsDir,
          modelUrl: 'http://127.0.0.1:${server.port}/model.gguf',
          serverArchiveUrl: 'http://127.0.0.1:${server.port}/llama.tar.gz',
          findServer: () => binServer.existsSync() ? binServer.path : null,
        );
        expect(model.isReady, isFalse);

        await model.download();

        expect(model.isReady, isTrue);
        expect(serverDownloads, 1);
        expect(modelDownloads, 1);
        expect(binServer.existsSync(), isTrue);
        expect(File('${temp.path}/bin/libllama.dylib').existsSync(), isTrue);
      },
    );

    test(
      'selects the right llama-server release archive per OS/ABI and extracts .zip archives',
      () async {
        expect(
          LlamaServer.releaseArchiveName(abi: Abi.macosArm64),
          'llama-b11429-bin-macos-arm64.tar.gz',
        );
        expect(
          LlamaServer.releaseArchiveName(abi: Abi.macosX64),
          'llama-b11429-bin-macos-x64.tar.gz',
        );
        expect(
          LlamaServer.releaseArchiveName(abi: Abi.linuxX64),
          'llama-b11429-bin-ubuntu-x64.tar.gz',
        );
        expect(
          LlamaServer.releaseArchiveName(abi: Abi.windowsX64),
          'llama-b11429-bin-win-cpu-x64.zip',
        );

        final zipArchive = Archive()
          ..addFile(
            ArchiveFile(
              'llama-b11429/${LlamaServer.binaryName}',
              4,
              utf8.encode('test'),
            ),
          )
          ..addFile(
            ArchiveFile('llama-b11429/llama.dll', 3, utf8.encode('dll')),
          );
        final zipFile = File('${temp.path}/llama.zip')
          ..writeAsBytesSync(ZipEncoder().encode(zipArchive));
        final outBin = Directory('${temp.path}/zip_bin');
        final extracted = await LlamaServer.extractArchive(zipFile, outBin);
        expect(File(extracted).existsSync(), isTrue);
        expect(File('${outBin.path}/llama.dll').existsSync(), isTrue);
      },
    );
  });
}
