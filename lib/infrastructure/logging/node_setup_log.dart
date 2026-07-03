import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Durable, append-only transcript of the background node-setup / auto-install
/// run, written next to the CLI's own logs at `~/.grid/logs/app_node_setup.log`.
///
/// Why: [NodeSetupController]'s in-app log lives only in memory (capped at 400
/// lines) and is gone the moment the app closes — so when auto-install silently
/// fails on a user's machine there is nothing left to debug. This leaves a file
/// we can ask the user to send us. The format is deliberately plain ASCII with
/// numbered steps, clock stamps and per-step timing so a non-technical user (or
/// us) can skim it in any text viewer without mojibake.
abstract interface class NodeSetupLog {
  /// Opens a new run section: a header listing the numbered [stepTitles].
  void startRun(List<String> stepTitles);

  /// Marks the start of step [number] of [total] (both 1-based).
  void startStep(int number, int total, String title);

  /// Appends one line of streamed output for the current step. [isError] tags
  /// stderr so failures stand out in the transcript.
  void write(String line, {bool isError = false});

  /// Marks the current step finished with a short [result] (e.g. `done`,
  /// `failed`, `cancelled`); the elapsed time is appended automatically.
  void endStep(String result);

  /// Closes the current run with a final [outcome] footer.
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
  static const _rule = '================================================';

  DateTime? _runStart;
  DateTime? _stepStart;
  int _stepNumber = 0;
  int _stepTotal = 0;
  String _stepTitle = '';

  @override
  void startRun(List<String> stepTitles) {
    _rotateIfLarge();
    final start = DateTime.now();
    _runStart = start;
    final plan = StringBuffer();
    for (var i = 0; i < stepTitles.length; i++) {
      plan.write('\n   ${i + 1}. ${stepTitles[i]}');
    }
    _raw('\n$_rule\n'
        ' Grid node setup\n'
        ' Started ${_stamp(start)}\n'
        ' Plan:$plan\n'
        '$_rule');
  }

  @override
  void startStep(int number, int total, String title) {
    _stepStart = DateTime.now();
    _stepNumber = number;
    _stepTotal = total;
    _stepTitle = title;
    _line('-- Step $number/$total: $title --');
  }

  @override
  void write(String line, {bool isError = false}) =>
      _line(isError ? '!! $line' : '   $line');

  @override
  void endStep(String result) {
    final took = _stepStart == null
        ? ''
        : ' (${_dur(DateTime.now().difference(_stepStart!))})';
    _line('-- Step $_stepNumber/$_stepTotal $result$took: $_stepTitle --');
    _stepStart = null;
  }

  @override
  void endRun(String outcome) {
    final total = _runStart == null
        ? ''
        : ' (total ${_dur(DateTime.now().difference(_runStart!))})';
    _raw(' Result: $outcome\n Ended ${_stamp(DateTime.now())}$total\n$_rule\n');
    _runStart = null;
  }

  /// Emit a clock-stamped transcript line.
  void _line(String text) => _raw('[${_clock(DateTime.now())}] $text');

  void _raw(String block) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync('$block\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort logging; never surface an IO failure into the setup flow.
    }
  }

  String _stamp(DateTime t) =>
      '${t.year}-${_pad2(t.month)}-${_pad2(t.day)} ${_clock(t)}';

  String _clock(DateTime t) =>
      '${_pad2(t.hour)}:${_pad2(t.minute)}:${_pad2(t.second)}';

  String _dur(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}m${s % 60}s' : '${s}s';
  }

  String _pad2(int n) => n.toString().padLeft(2, '0');

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
