import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'dictionary_builder.dart';
import 'dictionary_index.dart';
import 'word_lookup.dart';

enum DictionaryStatus { unsupported, missing, installing, ready, failed }

/// Offline dictionaries, one per book language, as the UI sees them.
abstract class Dictionaries extends ChangeNotifier {
  DictionaryStatus status(String language);

  /// Install progress in [0, 1], null if unknown.
  double? progress(String language);
  String? error(String language);
  String approximateSize(String language);

  bool supports(String language) =>
      status(language) != DictionaryStatus.unsupported;
  bool isReady(String language) => status(language) == DictionaryStatus.ready;

  Future<void> install(String language);
  void cancel(String language);

  /// Looks words up in [language]; null if its dictionary isn't installed.
  Future<WordLookup?> lookup(String language);
}

/// Dictionaries built on this Mac from Wiktionary: the inflections of the
/// English Wiktionary and the definitions of the French one, as extracted
/// by kaikki.org. Both are downloaded (gzip-compressed) and turned into an
/// index in a background isolate; only the index is kept.
class WiktionaryDictionaries extends Dictionaries {
  WiktionaryDictionaries(this.directory);

  /// Where each language's index is kept, in a folder named by its code.
  final Directory directory;

  /// Supported languages: their names on kaikki.org for the English and
  /// French Wiktionaries, and the approximate download size.
  static const sources = {
    'de': ('German', 'Allemand', '210 MB'),
    'es': ('Spanish', 'Espagnol', '130 MB'),
  };

  /// Written last: the index is complete. Bump [_version] to rebuild
  /// indexes made by an older builder.
  static const _marker = 'complete';
  static const _version = '1';

  final _installs = <String, _Install>{};
  final _errors = <String, String>{};
  final _lookups = <String, Future<WordLookup>>{};

  Directory _dir(String language) =>
      Directory(p.join(directory.path, language));

  static List<Uri> urls(String language) {
    final (english, french, _) = sources[language]!;
    return [
      Uri.parse(
        'https://kaikki.org/dictionary/$english/kaikki.org-dictionary-$english.jsonl',
      ),
      Uri.parse(
        'https://kaikki.org/frwiktionary/$french/kaikki.org-dictionary-$french.jsonl',
      ),
    ];
  }

  @override
  DictionaryStatus status(String language) {
    if (!sources.containsKey(language)) return DictionaryStatus.unsupported;
    if (_installs.containsKey(language)) return DictionaryStatus.installing;
    if (_errors.containsKey(language)) return DictionaryStatus.failed;
    final marker = File(p.join(_dir(language).path, _marker));
    return marker.existsSync() && marker.readAsStringSync() == _version
        ? DictionaryStatus.ready
        : DictionaryStatus.missing;
  }

  @override
  double? progress(String language) => _installs[language]?.progress;

  @override
  String? error(String language) => _errors[language];

  @override
  String approximateSize(String language) =>
      sources[language]?.$3 ?? 'unknown size';

  @override
  Future<WordLookup?> lookup(String language) async {
    if (!isReady(language)) return null;
    return _lookups[language] ??= DictionaryIndex.open(_dir(language))
        .then((index) => IndexWordLookup(index, language));
  }

  @override
  Future<void> install(String language) async {
    if (!sources.containsKey(language) || _installs.containsKey(language)) {
      return;
    }
    _errors.remove(language);
    final install = _installs[language] = _Install();
    notifyListeners();
    final part = Directory('${_dir(language).path}.part');
    final messages = ReceivePort();
    try {
      if (part.existsSync()) await part.delete(recursive: true);
      install.isolate = await Isolate.spawn(
        _build,
        (messages.sendPort, language, urls(language), part.path),
        onExit: messages.sendPort,
        onError: messages.sendPort,
      );
      // The isolate's exit notice (null) follows "done": stop listening at
      // "done".
      listen:
      await for (final message in messages) {
        if (install.cancelled) break;
        switch (message) {
          case double progress:
            install.progress = progress;
            notifyListeners();
          case 'done':
            await File(p.join(part.path, _marker)).writeAsString(_version);
            final target = _dir(language);
            if (target.existsSync()) await target.delete(recursive: true);
            await part.rename(target.path);
            _lookups.remove(language);
            break listen;
          case String error:
            throw Exception(error);
          case List<Object?> error: // uncaught in the isolate
            throw Exception(error.firstOrNull);
          case null: // the isolate exited before "done"
            throw Exception('The dictionary builder stopped unexpectedly.');
        }
      }
    } catch (e) {
      if (!install.cancelled) _errors[language] = '$e';
    } finally {
      messages.close();
      install.isolate?.kill(priority: Isolate.immediate);
      _installs.remove(language);
      if (part.existsSync()) {
        await part.delete(recursive: true).catchError((_) => part);
      }
      notifyListeners();
    }
  }

  @override
  void cancel(String language) {
    final install = _installs[language];
    if (install == null) return;
    install.cancelled = true;
    install.isolate?.kill(priority: Isolate.immediate);
    _installs.remove(language);
    notifyListeners();
  }

  /// Runs in the isolate: downloads both extracts, builds the index into
  /// the given folder, and sends progress (doubles), then `done` or an
  /// error message.
  static Future<void> _build((SendPort, String, List<Uri>, String) args) async {
    final (port, language, urls, out) = args;
    try {
      final builder = DictionaryBuilder(language);
      // The English extract is the bigger one.
      const shares = [0.6, 0.35];
      var done = 0.0;
      for (final (i, url) in urls.indexed) {
        final add = i == 0 ? builder.addInflections : builder.addDefinitions;
        final start = done;
        await builder.addLines(
          _download(url, (f) => port.send(start + f * shares[i])),
          add,
        );
        done += shares[i];
      }
      port.send(done);
      await builder.write(Directory(out));
      port.send('done');
    } catch (e) {
      port.send('Could not build the dictionary: $e');
    }
  }

  /// Lines of the JSON-lines file at [url], downloaded gzip-compressed.
  static Stream<String> _download(
    Uri url,
    void Function(double) onProgress,
  ) async* {
    final client = HttpClient()
      ..autoUncompress = false
      ..userAgent = 'epub_reader (offline dictionary)';
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final total = response.contentLength;
      var received = 0;
      var reported = 0.0;
      Stream<List<int>> body = response.map((chunk) {
        received += chunk.length;
        if (total > 0 && received / total - reported > 0.005) {
          reported = received / total;
          onProgress(reported);
        }
        return chunk;
      });
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding == 'gzip') body = body.transform(gzip.decoder);
      yield* body.transform(utf8.decoder).transform(const LineSplitter());
    } finally {
      client.close(force: true);
    }
  }
}

class _Install {
  Isolate? isolate;
  double? progress = 0;
  bool cancelled = false;
}
