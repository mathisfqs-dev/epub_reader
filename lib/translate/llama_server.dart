import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// A llama-server process serving one GGUF model on 127.0.0.1, protected by
/// a random API key.
///
/// A pid file remembers the running server, so that one left behind by a
/// crash of the app is stopped on the next start.
class LlamaServer {
  LlamaServer._(this._process, this.baseUri, this.apiKey, this._pidFile) {
    _process.exitCode.then((code) {
      _exitCode = code;
      if (_pidFile.existsSync()) _pidFile.deleteSync();
    });
  }

  final Process _process;
  final Uri baseUri;
  final String apiKey;
  final File _pidFile;
  int? _exitCode;

  bool get isRunning => _exitCode == null;
  Future<int> get exitCode => _process.exitCode;
  int get pid => _process.pid;

  /// Where llama-server is looked for, in order: the app bundle
  /// (Contents/Resources/llama/), [extraDirectory], then Homebrew.
  static List<String> candidates({String? extraDirectory}) {
    final exe = Platform.resolvedExecutable; // …/X.app/Contents/MacOS/X
    final contents = p.dirname(p.dirname(exe));
    return [
      ?Platform.environment['LLAMA_SERVER'],
      p.join(contents, 'Resources', 'llama', 'llama-server'),
      if (extraDirectory != null) p.join(extraDirectory, 'llama-server'),
      '/opt/homebrew/bin/llama-server',
      '/usr/local/bin/llama-server',
    ];
  }

  /// The first llama-server executable found, if any.
  static String? find({String? extraDirectory}) {
    for (final path in candidates(extraDirectory: extraDirectory)) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Starts [binary] on [model] and waits until the model is loaded.
  ///
  /// The server's output goes to [logFile]. Throws a [LlamaServerException]
  /// if it exits or isn't ready within [timeout].
  static Future<LlamaServer> start({
    required String binary,
    required String model,
    required File pidFile,
    required File logFile,
    int contextSize = 8192,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    await stopStale(pidFile);
    final port = await _freePort();
    final apiKey = _randomKey();
    await logFile.parent.create(recursive: true);
    final log = logFile.openWrite();
    final process = await Process.start(binary, [
      '--model',
      model,
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      '--api-key',
      apiKey,
      '--ctx-size',
      '$contextSize',
      '--parallel',
      '1',
      '--no-webui',
    ]);
    await pidFile.parent.create(recursive: true);
    pidFile.writeAsStringSync('${process.pid}');

    // The output must be drained, or the server blocks once the pipe is full.
    final tail = <String>[];
    void keep(String line) {
      log.writeln(line);
      tail.add(line);
      if (tail.length > 20) tail.removeAt(0);
    }

    for (final stream in [process.stdout, process.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(keep, onError: (_) {});
    }
    process.exitCode.then((_) => log.close());

    final server = LlamaServer._(
      process,
      Uri.parse('http://127.0.0.1:$port'),
      apiKey,
      pidFile,
    );
    final deadline = DateTime.now().add(timeout);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      while (true) {
        if (!server.isRunning) {
          throw LlamaServerException(
            'llama-server stopped (exit code ${server._exitCode}).',
            tail.join('\n'),
          );
        }
        if (DateTime.now().isAfter(deadline)) {
          await server.stop();
          throw LlamaServerException(
            'The model did not load in ${timeout.inSeconds} s.',
            tail.join('\n'),
          );
        }
        // 503 while the model is loading, 200 once ready.
        if (await _healthy(client, server.baseUri)) return server;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _healthy(HttpClient client, Uri base) async {
    try {
      final request = await client.getUrl(base.resolve('/health'));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Stops the server recorded in [pidFile] if it is still a llama-server.
  static Future<void> stopStale(File pidFile) async {
    if (!pidFile.existsSync()) return;
    final pid = int.tryParse(pidFile.readAsStringSync().trim());
    pidFile.deleteSync();
    if (pid == null) return;
    final ps = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
    if (!'${ps.stdout}'.contains('llama-server')) return;
    Process.killPid(pid);
  }

  /// Stops the server: SIGTERM, then SIGKILL after [grace].
  Future<void> stop({Duration grace = const Duration(seconds: 3)}) async {
    if (!isRunning) return;
    _process.kill();
    try {
      await _process.exitCode.timeout(grace);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
    }
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static String _randomKey() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }
}

class LlamaServerException implements Exception {
  LlamaServerException(this.message, [this.log = '']);
  final String message;

  /// The last lines printed by the server.
  final String log;

  @override
  String toString() => message;
}
