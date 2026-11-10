import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:epub_reader/translate/languages.dart';
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
}
