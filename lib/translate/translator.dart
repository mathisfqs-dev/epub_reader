import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'languages.dart';

/// What to translate: [text] from [source] into [target] (language codes),
/// with the paragraph around it as [context] when known.
class TranslationRequest {
  const TranslationRequest({
    required this.text,
    required this.source,
    required this.target,
    this.context,
  });

  final String text;
  final String source;
  final String target;
  final String? context;

  /// Longest text sent to the model, in characters (the server's context is
  /// 8192 tokens, shared by the prompt and the answer).
  static const maxLength = 6000;

  /// Longer passages are sent without context: they carry their own, and the
  /// prompt would repeat them.
  static const maxContextPassage = 1500;

  TranslationRequest copyWith({String? target}) => TranslationRequest(
    text: text,
    source: source,
    target: target ?? this.target,
    context: context,
  );

  /// The chat messages sent to the model.
  List<Map<String, String>> messages() {
    final from = TranslationLanguage.of(source).name;
    final into = TranslationLanguage.of(target).name;
    final passage = text.trim();
    final around = context?.trim();
    final hasContext =
        around != null &&
        around.isNotEmpty &&
        around != passage &&
        around.length <= maxLength &&
        passage.length <= maxContextPassage;
    // Tags keep the model from following instructions that happen to be in
    // the book. With context, Gemma 3 4B still translated it too in 4 of 18
    // tries; restating the passage at the end brought that to 0 of 18.
    final what = hasContext
        ? 'The user gives a passage taken from a book, inside <passage> tags, '
              'and the text around it inside <context> tags. Translate ONLY '
              'the passage, using the context to choose the right meaning.'
        : 'The user gives a passage taken from a book, inside <passage> '
              'tags. Translate it.';
    return [
      {
        'role': 'system',
        'content':
            'You are a literary translator from $from into $into. $what '
            'Keep the tone, register and punctuation style. Reply with the '
            '$into translation of the passage only: no tags, notes or '
            'explanations.',
      },
      {
        'role': 'user',
        'content': hasContext
            ? '<context>\n$around\n</context>\n\n'
                  '<passage>\n$passage\n</passage>\n\n'
                  'Translate only this passage into $into: «$passage»'
            : '<passage>\n$passage\n</passage>',
      },
    ];
  }
}

class TranslationException implements Exception {
  TranslationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Translates text, streaming the result piece by piece.
abstract interface class Translator {
  /// Pieces of the translation, in order. Cancelling the subscription stops
  /// the generation.
  Stream<String> translate(TranslationRequest request);
}

/// Talks to an OpenAI-compatible chat API (`POST /v1/chat/completions`,
/// streamed as server-sent events), as served by llama-server.
class OpenAiChatTranslator implements Translator {
  OpenAiChatTranslator({required this.baseUri, this.apiKey, this.model});

  final Uri baseUri;
  final String? apiKey;
  final String? model;

  static const temperature = 0.2;

  @override
  Stream<String> translate(TranslationRequest request) {
    final client = HttpClient();
    late final StreamController<String> out;
    StreamSubscription<String>? lines;
    final done = Completer<void>();

    Future<void> run() async {
      try {
        final http = await client.postUrl(
          baseUri.resolve('/v1/chat/completions'),
        );
        http.headers.contentType = ContentType.json;
        if (apiKey != null) {
          http.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
        }
        http.add(
          utf8.encode(
            jsonEncode({
              'model': ?model,
              'messages': request.messages(),
              'stream': true,
              'temperature': temperature,
              'max_tokens': 2048,
            }),
          ),
        );
        final response = await http.close();
        if (response.statusCode != 200) {
          final body = await utf8.decodeStream(response);
          throw TranslationException(
            'The model server answered ${response.statusCode}: '
            '${_errorMessage(body)}',
          );
        }
        if (done.isCompleted) return; // cancelled meanwhile
        lines = response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                final event = parseSseLine(line);
                switch (event) {
                  case SseDone():
                    if (!done.isCompleted) done.complete();
                  case SseDelta(:final text):
                    if (text.isNotEmpty) out.add(text);
                  case SseError(:final message):
                    if (!done.isCompleted) {
                      done.completeError(TranslationException(message));
                    }
                  case null:
                    break;
                }
              },
              onError: (Object e) {
                if (!done.isCompleted) done.completeError(e);
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              cancelOnError: true,
            );
        await done.future;
      } catch (e) {
        if (!out.isClosed) {
          out.addError(
            e is TranslationException
                ? e
                : TranslationException('Could not reach the model server: $e'),
          );
        }
      } finally {
        await lines?.cancel();
        client.close(force: true);
        if (!out.isClosed) await out.close();
      }
    }

    out = StreamController<String>(
      onListen: run,
      onCancel: () async {
        // Closing the connection makes llama-server stop generating.
        if (!done.isCompleted) done.complete();
        client.close(force: true);
        await lines?.cancel();
      },
    );
    return out.stream;
  }

  static String _errorMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is Map) {
        return '${(json['error'] as Map)['message']}';
      }
    } on FormatException {
      // Not JSON.
    }
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }
}

sealed class SseEvent {
  const SseEvent();
}

class SseDelta extends SseEvent {
  const SseDelta(this.text);
  final String text;
}

class SseDone extends SseEvent {
  const SseDone();
}

class SseError extends SseEvent {
  const SseError(this.message);
  final String message;
}

/// Parses one line of a streamed chat completion. Null for blank lines,
/// comments and chunks without text.
SseEvent? parseSseLine(String line) {
  if (!line.startsWith('data:')) return null;
  final data = line.substring(5).trim();
  if (data == '[DONE]') return const SseDone();
  if (data.isEmpty) return null;
  final Object? json;
  try {
    json = jsonDecode(data);
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  final error = json['error'];
  if (error != null) {
    return SseError(error is Map ? '${error['message']}' : '$error');
  }
  final choices = json['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  if (first is! Map) return null;
  final delta = first['delta'];
  final content = delta is Map ? delta['content'] : null;
  return content is String ? SseDelta(content) : null;
}
