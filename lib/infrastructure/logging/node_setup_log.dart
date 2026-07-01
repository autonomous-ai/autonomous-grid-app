import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Durable, append-only transcript of the background node-setup / auto-install
/// run, written next to the CLI's own logs at `~/.grid/logs/app_node_setup.log`.
///
/// Why: [NodeSetupController]'s in-app log lives only in memory (capped at 400
/// lines) and is gone the moment the app closes — so when auto-install silently
/// fails on a user's machine there is nothing left to debug. This leaves a file
/// we can ask the user to send us.
abstract interface class NodeSetupLog {
  /// Opens a new run section with a timestamped header describing [summary].
  void startRun(String summary);

  /// Appends one transcript line (a step boundary or streamed CLI output).
  void write(String line);

  /// Closes the current run with a timestamped [outcome] footer.
  void endRun(String outcome);
}

/// [NodeSetupLog] backed by a real file under `~/.grid/logs`. Writes are
/// synchronous and flushed so a line survives even if the app is force-quit
/// mid-install; any IO error is swallowed — logging must never break the setup
/// flow it only observes.
class FileNodeSetupLog implements NodeSetupLog {
  FileNodeSetupLog(this._file);

  final File _file;

  /// Keep the log bounded: rotate to a single `.old` sibling once it grows past
  /// this. Each run is a few KB, so this holds many runs before rotating.
  static const _maxBytes = 512 * 1024;

  @override
  void startRun(String summary) {
    _rotateIfLarge();
    _emit('===== run start: $summary =====');
  }

  @override
  void write(String line) => _emit(line);

  @override
  void endRun(String outcome) => _emit('===== run end: $outcome =====');

  void _emit(String line) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        '${DateTime.now().toIso8601String()}  $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Best-effort logging; never surface an IO failure into the setup flow.
    }
  }

  void _rotateIfLarge() {
    try {
      if (!_file.existsSync() || _file.lengthSync() < _maxBytes) return;
      final old = File('${_file.path}.old');
      if (old.existsSync()) old.deleteSync();
      _file.renameSync(old.path);
    } catch (_) {
      // If rotation fails, keep appending to the existing file.
    }
  }
}

/// The setup transcript sink. A real file by default; override in dev/test with
/// an in-memory fake so tests never touch `~/.grid`.
final nodeSetupLogProvider =
    Provider<NodeSetupLog>((ref) => FileNodeSetupLog(GridPaths.nodeSetupLog));
