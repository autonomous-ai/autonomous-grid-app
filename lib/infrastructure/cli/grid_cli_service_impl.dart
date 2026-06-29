import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'grid_cli_service.dart';
import 'host_environment.dart';
import 'parsers/download_progress.dart';

/// Real implementation that spawns the `grid` binary. Always argv form
/// (`runInShell: false`) — never string interpolation into a shell — to avoid
/// command injection (CLI_Integration_Contract §2).
class GridCliServiceImpl implements GridCliService {
  GridCliServiceImpl(this.executable) : _env = _buildEnv();

  /// Absolute path to `grid`, from [GridResolver].
  final String executable;

  /// Environment for spawned `grid` processes:
  /// - `PYTHONUNBUFFERED` so the piped Python CLI flushes stdout per line —
  ///   without it, streamed output (e.g. the device-login URL) is withheld
  ///   until the process exits, which it doesn't while polling.
  /// - `PYTHONUTF8` / `PYTHONIOENCODING` force UTF-8 I/O. A Finder-launched GUI
  ///   app inherits no `LANG`, so the frozen Python `grid` would otherwise pick
  ///   ASCII stdio and crash with `UnicodeEncodeError` the moment it prints a
  ///   non-ASCII char (e.g. the "–"/"—" in its own messages) — failing install,
  ///   joining an engine, etc. with exit 1.
  /// - an augmented `PATH` (+ a UTF-8 `LANG`) so `grid`'s own children (brew,
  ///   docker, cmake, llama-server) resolve and also emit UTF-8 — a GUI app
  ///   inherits only a minimal environment. The `PATH` comes from
  ///   [HostEnvironment], shared with the app's own tool detection so they agree.
  final Map<String, String> _env;

  static Map<String, String> _buildEnv() {
    final env = <String, String>{
      'PYTHONUNBUFFERED': '1',
      'PYTHONUTF8': '1',
      'PYTHONIOENCODING': 'utf-8',
    };
    if (!Platform.isWindows) {
      env['PATH'] = HostEnvironment.path();
      // Keep the user's locale when present; otherwise give children a sane
      // UTF-8 default instead of the C/POSIX (ASCII) locale.
      final lang = Platform.environment['LANG'];
      env['LANG'] = (lang != null && lang.isNotEmpty) ? lang : 'en_US.UTF-8';
    }
    return env;
  }

  @override
  Future<CliResult> run(List<String> args) async {
    final result = await Process.run(executable, args,
        runInShell: false, environment: _env);
    return CliResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }

  @override
  Future<GridProcess> start(List<String> args) async {
    final process = await Process.start(executable, args,
        runInShell: false, environment: _env);
    final controller = StreamController<CliLine>();

    final outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => controller.add(CliLine(isStderr: false, text: line)),
            onError: controller.addError);
    final errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => controller.add(CliLine(isStderr: true, text: line)),
            onError: controller.addError);

    unawaited(process.exitCode.whenComplete(() async {
      await outSub.cancel();
      await errSub.cancel();
      await controller.close();
    }));

    return GridProcess(
      lines: controller.stream,
      exitCode: process.exitCode,
      kill: () => process.kill(ProcessSignal.sigterm),
    );
  }

  @override
  Stream<DownloadProgress> pull(List<String> args) async* {
    final process =
        await Process.start(executable, args,
        runInShell: false, environment: _env);
    // Progress is written with `\r`, so decode bytes and split on it ourselves
    // rather than using a line splitter (which only breaks on `\n`).
    final controller = StreamController<DownloadProgress>();

    process.stderr.transform(utf8.decoder).listen(
      (chunk) {
        final progress = DownloadProgress.latest(chunk);
        if (progress != null) controller.add(progress);
      },
      onError: controller.addError,
    );

    unawaited(process.exitCode.then((_) => controller.close()));
    yield* controller.stream;
  }
}
