import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import 'log_file.dart';

/// Durable, append-only transcript of every `grid` CLI call the app makes,
/// written to `~/.grid/logs/app_cli.log` next to the CLI's own logs.
///
/// Why: the in-app Debug tab ([commandLogProvider]) is a capped in-memory ring
/// buffer that vanishes the moment the app closes, so when a command misbehaves
/// on a user's machine there is nothing left to inspect. This leaves a file we
/// can ask them to send us. Concurrent CLI calls interleave in the file, so each
/// line is tagged with a per-call id (`#3`) to keep a command's output readable.
abstract interface class CliLog {
  /// Opens a section for one CLI invocation. [command] is the display line
  /// (`grid --remote login`). Returns a handle to append its output and close
  /// it.
  CliLogEntry begin(String command);
}

/// Handle to one in-flight CLI invocation's transcript section, returned by
/// [CliLog.begin]. Append streamed output with [output]; close it with [end].
abstract interface class CliLogEntry {
  /// Append one line of the command's output; [isError] tags stderr so failures
  /// stand out.
  void output(String line, {bool isError = false});

  /// Close the section with how the command ended. Idempotent — a second call is
  /// ignored so a cancelled stream and its exit code don't double-close.
  void end({int? exitCode, Duration? duration, String? error});
}

/// [CliLog] backed by a real file under `~/.grid/logs`. Writes are synchronous
/// and flushed (see [LogFile]); IO errors are swallowed — logging must never
/// break the CLI call it observes.
class FileCliLog implements CliLog {
  FileCliLog(File file) : _file = LogFile(file);

  final LogFile _file;
  int _seq = 0;

  @override
  CliLogEntry begin(String command) {
    _file.rotateIfLarge();
    final id = ++_seq;
    final start = DateTime.now();
    _file.append('[${logClock(start)}] #$id \$ $command');
    return _FileCliLogEntry(_file, id, start);
  }
}

class _FileCliLogEntry implements CliLogEntry {
  _FileCliLogEntry(this._file, this._id, this._start);

  final LogFile _file;
  final int _id;
  final DateTime _start;
  bool _ended = false;

  @override
  void output(String line, {bool isError = false}) {
    if (_ended) return;
    // `!` gutter marks stderr so failures stand out; `|` for normal output.
    final tag = isError ? '!' : '|';
    _file.append('[${logClock(DateTime.now())}] #$_id $tag $line');
  }

  @override
  void end({int? exitCode, Duration? duration, String? error}) {
    if (_ended) return;
    _ended = true;
    final took = logDuration(duration ?? DateTime.now().difference(_start));
    final code = exitCode != null ? ' exit=$exitCode' : '';
    final err = error != null ? ' error: $error' : '';
    _file.append('[${logClock(DateTime.now())}] #$_id ← done$code ($took)$err');
  }
}

/// The CLI transcript sink. A real file by default; override in dev/test with an
/// in-memory fake so tests never touch `~/.grid/logs`.
final cliLogProvider = Provider<CliLog>((ref) => FileCliLog(GridPaths.cliLog));
