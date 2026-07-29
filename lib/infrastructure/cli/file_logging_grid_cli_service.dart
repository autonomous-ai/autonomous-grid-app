import 'dart:async';
import 'dart:convert';

import '../logging/cli_log.dart';
import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// Decorates a [GridCliService] to append every invocation — command, streamed
/// output, and outcome — to a durable [CliLog] file (`~/.grid/logs/app_cli.log`).
///
/// A pure cross-cutting concern: it tees the output back to the caller unchanged
/// and never alters the real work. Complements [LoggingGridCliService], which
/// records the same calls to the in-memory Debug tab; this one is what survives
/// an app restart so a user can send us the transcript.
class FileLoggingGridCliService implements GridCliService {
  FileLoggingGridCliService(this._inner, this._log);

  final GridCliService _inner;
  final CliLog _log;

  static String _display(List<String> args) => 'grid ${args.join(' ')}';

  @override
  Future<CliResult> run(List<String> args, {Duration? timeout}) async {
    final entry = _log.begin(_display(args));
    try {
      final result = await _inner.run(args, timeout: timeout);
      _writeBlock(entry, result.stdout, isError: false);
      _writeBlock(entry, result.stderr, isError: true);
      entry.end(exitCode: result.exitCode);
      return result;
    } catch (e) {
      entry.end(error: e.toString());
      rethrow;
    }
  }

  @override
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    // Only [args] is recorded; [environment] (which may hold a secret) is not.
    final entry = _log.begin(_display(args));
    final GridProcess process;
    try {
      process = await _inner.start(args, environment: environment);
    } catch (e) {
      entry.end(error: e.toString());
      rethrow;
    }
    // Log the exit independently of the caller draining `lines`, mirroring
    // [LoggingGridCliService]. [CliLogEntry.end] is idempotent, so whichever of
    // the exit and stream-completion happens first closes the section.
    unawaited(
      process.exitCode.then(
        (code) => entry.end(exitCode: code),
        onError: (Object e) => entry.end(error: e.toString()),
      ),
    );
    return GridProcess(
      lines: _teeLines(process.lines, entry),
      exitCode: process.exitCode,
      kill: process.kill,
    );
  }

  @override
  Stream<DownloadProgress> pull(List<String> args) async* {
    // Downloads emit a fast progress carousel — logging every frame would flood
    // the file, so we record only the command and its final state.
    final entry = _log.begin(_display(args));
    DownloadProgress? last;
    var finished = false;
    void end({int? exitCode, String? error}) {
      if (finished) return;
      finished = true;
      if (last != null) entry.output(_describe(last));
      entry.end(exitCode: exitCode, error: error);
    }

    try {
      await for (final progress in _inner.pull(args)) {
        last = progress;
        yield progress;
      }
      end(exitCode: 0);
    } catch (e) {
      end(error: e.toString());
      rethrow;
    } finally {
      // Cancelled mid-stream (user hit Cancel): close the section here too.
      end(exitCode: 0);
    }
  }

  /// Append a captured stdout/stderr blob line-by-line, skipping an empty block.
  void _writeBlock(CliLogEntry entry, String text, {required bool isError}) {
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) return;
    for (final line in const LineSplitter().convert(trimmed)) {
      entry.output(line, isError: isError);
    }
  }

  /// Pass every streamed line through to the caller while copying it to [entry].
  /// A single-subscription controller preserves the inner stream's semantics
  /// (one listener, pause/resume, cancel) so login/join flows are untouched.
  Stream<CliLine> _teeLines(Stream<CliLine> source, CliLogEntry entry) {
    final controller = StreamController<CliLine>();
    StreamSubscription<CliLine>? sub;
    controller.onListen = () {
      sub = source.listen(
        (line) {
          entry.output(line.text, isError: line.isStderr);
          controller.add(line);
        },
        onError: controller.addError,
        onDone: controller.close,
      );
    };
    controller
      ..onPause = (() => sub?.pause())
      ..onResume = (() => sub?.resume())
      ..onCancel = (() => sub?.cancel());
    return controller.stream;
  }

  static String _describe(DownloadProgress p) {
    final done = p.doneMb.toStringAsFixed(1);
    if (p.totalMb == null) return 'downloaded $done MB';
    final total = p.totalMb!.toStringAsFixed(1);
    final pct = p.pct?.toStringAsFixed(1);
    return 'downloaded $done / $total MB${pct != null ? ' ($pct%)' : ''}';
  }
}
