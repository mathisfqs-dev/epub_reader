import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
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

  /// Executable name of the server (`llama-server.exe` on Windows).
  static String get binaryName =>
      Platform.isWindows ? 'llama-server.exe' : 'llama-server';

  /// Official llama.cpp release archive downloaded when no local
  /// `llama-server` is already installed.
  static const releaseBuild = 'b11429';
  static const _releaseBase =
      'https://github.com/ggml-org/llama.cpp/releases/download/$releaseBuild';

  /// Archive filename for the current OS and CPU architecture.
  static String releaseArchiveName({Abi? abi}) {
    return switch (abi ?? Abi.current()) {
      Abi.macosArm64 => 'llama-$releaseBuild-bin-macos-arm64.tar.gz',
      Abi.macosX64 => 'llama-$releaseBuild-bin-macos-x64.tar.gz',
      Abi.linuxArm64 => 'llama-$releaseBuild-bin-ubuntu-arm64.tar.gz',
      Abi.linuxX64 => 'llama-$releaseBuild-bin-ubuntu-x64.tar.gz',
      Abi.windowsArm64 => 'llama-$releaseBuild-bin-win-cpu-arm64.zip',
      Abi.windowsX64 => 'llama-$releaseBuild-bin-win-cpu-x64.zip',
      final other => throw UnsupportedError('No llama-server build for $other'),
    };
  }

  static String get releaseUrl => '$_releaseBase/${releaseArchiveName()}';

  /// Where llama-server is looked for, in order: `$LLAMA_SERVER`, the app
  /// bundle, system package paths (Homebrew / Linux `/usr/bin`, Windows
  /// WinGet/Scoop), then [extraDirectory] (`Application Support/…/bin/`).
  static List<String> candidates({String? extraDirectory}) {
    final exe = Platform.resolvedExecutable;
    final bin = binaryName;
    final list = <String>[?Platform.environment['LLAMA_SERVER']];
    if (Platform.isMacOS) {
      final contents = p.dirname(p.dirname(exe));
      list.addAll([
        p.join(contents, 'Resources', 'llama', bin),
        '/opt/homebrew/bin/$bin',
        '/usr/local/bin/$bin',
      ]);
    } else if (Platform.isLinux) {
      list.addAll([
        p.join(p.dirname(exe), 'llama', bin),
        '/usr/local/bin/$bin',
        '/usr/bin/$bin',
        '/home/linuxbrew/.linuxbrew/bin/$bin',
      ]);
    } else if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      final userProfile = Platform.environment['USERPROFILE'];
      list.addAll([
        p.join(p.dirname(exe), 'llama', bin),
        if (localAppData != null)
          p.join(localAppData, 'Microsoft', 'WinGet', 'Links', bin),
        if (userProfile != null) p.join(userProfile, 'scoop', 'shims', bin),
      ]);
    }
    if (extraDirectory != null) {
      list.add(p.join(extraDirectory, bin));
    }
    return list;
  }

  /// The first llama-server executable found, if any.
  static String? find({String? extraDirectory}) {
    for (final path in candidates(extraDirectory: extraDirectory)) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Extracts a `llama-*-bin-*.tar.gz` or `.zip` [archive] into [binDirectory]
  /// so `binDirectory/llama-server[.exe]` and its sibling shared libraries
  /// (`.dylib` / `.so` / `.dll`) are ready to run.
  static Future<String> extractArchive(
    File archive,
    Directory binDirectory,
  ) async {
    final staging = Directory('${binDirectory.path}.part');
    if (staging.existsSync()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final bin = binaryName;
    try {
      if (archive.path.endsWith('.zip') ||
          archive.path.endsWith('.zip.part')) {
        final decoded = ZipDecoder().decodeBytes(await archive.readAsBytes());
        for (final entry in decoded) {
          final outPath = p.join(staging.path, entry.name);
          if (entry.isFile) {
            final outFile = File(outPath);
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(entry.content as List<int>);
          } else {
            await Directory(outPath).create(recursive: true);
          }
        }
      } else {
        final tar = await Process.run('tar', [
          '-xzf',
          archive.path,
          '-C',
          staging.path,
        ]);
        if (tar.exitCode != 0) {
          throw ProcessException('tar', [], '${tar.stderr}');
        }
      }
      // The archive may put files at the top level or inside a single
      // `llama-bXXXX/` or `build/bin/` subfolder: find `llama-server[.exe]`
      // and move its containing folder to [binDirectory].
      File? found;
      await for (final entity in staging.list(recursive: true)) {
        if (entity is File && p.basename(entity.path) == bin) {
          found = entity;
          break;
        }
      }
      if (found == null) {
        throw StateError('The archive does not contain $bin');
      }
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', found.path]);
      }
      final sourceDir = found.parent;
      if (binDirectory.existsSync()) {
        await binDirectory.delete(recursive: true);
      }
      await binDirectory.parent.create(recursive: true);
      if (sourceDir.path == staging.path) {
        await staging.rename(binDirectory.path);
      } else {
        await sourceDir.rename(binDirectory.path);
        await staging.delete(recursive: true);
      }
      return p.join(binDirectory.path, bin);
    } catch (_) {
      if (staging.existsSync()) await staging.delete(recursive: true);
      rethrow;
    }
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
    if (Platform.isWindows) {
      final tasklist = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/NH',
      ]);
      if (!'${tasklist.stdout}'.toLowerCase().contains('llama-server')) return;
    } else {
      final ps = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      if (!'${ps.stdout}'.contains('llama-server')) return;
    }
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
