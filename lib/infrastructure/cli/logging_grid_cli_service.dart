import 'dart:async';

import 'command_log.dart';
import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// Decorates a [GridCliService] to record every invocation into
/// [CommandLogNotifier] for the Debug tab. A pure cross-cutting concern: it
/// delegates all real work to [_inner] and never consumes the output streams
/// the feature controllers listen to — it only awaits the exit code/completion.
class LoggingGridCliService implements GridCliService {
  LoggingGridCliService(this._inner, this._log);

  final GridCliService _inner;
  final CommandLogNotifier _log;

  /// The Debug-list summary: the line a user would have typed themselves.
  static String _line(List<String> args) => 'grid ${args.join(' ')}';

  /// The argv as a shell sees it, program first — what the Debug tab hands back
  /// when the command is copied.
  static List<String> _argv(List<String> args) => ['grid', ...args];

  @override
  Future<CliResult> run(List<String> args, {Duration? timeout}) async {
    final id = _log.begin(
      CliCallKind.run,
      _line(args),
      detail: CommandDetail(args: _argv(args)),
    );
    try {
      final result = await _inner.run(args, timeout: timeout);
      _log.finish(
        id,
        exitCode: result.exitCode,
        error: result.ok ? null : result.errorMessage,
      );
      return result;
    } catch (e) {
      _log.finish(id, error: e.toString());
      rethrow;
    }
  }

  @override
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    // Log [args] in full, and of [environment] only the variable *names* — a
    // value there may be a secret (e.g. an API-engine key), which is the whole
    // point of the env channel. See [CommandDetail.envKeys].
    final id = _log.begin(
      CliCallKind.start,
      _line(args),
      detail: CommandDetail(
        args: _argv(args),
        envKeys: environment?.keys.toList(growable: false) ?? const [],
      ),
    );
    try {
      final process = await _inner.start(args, environment: environment);
      // Finalize when the process exits; leave the lines stream for the caller.
      unawaited(
        process.exitCode.then(
          (code) => _log.finish(id, exitCode: code),
          onError: (Object e) => _log.finish(id, error: e.toString()),
        ),
      );
      return process;
    } catch (e) {
      _log.finish(id, error: e.toString());
      rethrow;
    }
  }

  @override
  Stream<DownloadProgress> pull(List<String> args) async* {
    final id = _log.begin(
      CliCallKind.pull,
      _line(args),
      detail: CommandDetail(args: _argv(args)),
    );
    var finished = false;
    void finish({int? exitCode, String? error}) {
      if (finished) return;
      finished = true;
      _log.finish(id, exitCode: exitCode, error: error);
    }

    try {
      yield* _inner.pull(args);
      finish(exitCode: 0);
    } catch (e) {
      finish(error: e.toString());
      rethrow;
    } finally {
      // Cancelled mid-stream (user hit Cancel): neither branch above ran, so
      // close the entry here — otherwise the Debug tab shows the pull stuck at
      // "running" forever.
      finish(exitCode: 0);
    }
  }
}
