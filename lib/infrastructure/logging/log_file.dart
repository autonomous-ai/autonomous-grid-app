import 'dart:io';

/// Best-effort append-only log file with size-based rotation to a single `.old`
/// sibling. Writes are synchronous and flushed so a line survives even if the
/// app is force-quit mid-write, and every IO error is swallowed — diagnostic
/// logging must never break the flow it only observes.
///
/// Shared low-level sink behind [FileCliLog] and [FileNodeSetupLog] so the
/// append/flush/rotate rules live in exactly one place.
class LogFile {
  LogFile(this._file, {this.maxBytes = 512 * 1024});

  final File _file;

  /// Rotate to a single `.old` sibling once the file grows past this. Callers
  /// invoke [rotateIfLarge] at a sensible boundary (never mid-record) so a run
  /// is not split across files.
  final int maxBytes;

  /// Append [block] followed by a newline. Creates the parent directory on
  /// demand; any failure is swallowed.
  void append(String block) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync('$block\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort: never surface an IO failure into the caller's flow.
    }
  }

  /// Rotate the file to `<path>.old` when it has grown past [maxBytes]. Call at
  /// a record boundary before the first [append] of a new section.
  void rotateIfLarge() {
    try {
      if (!_file.existsSync() || _file.lengthSync() < maxBytes) return;
      final old = File('${_file.path}.old');
      if (old.existsSync()) old.deleteSync();
      _file.renameSync(old.path);
    } catch (_) {
      // If rotation fails, keep appending to the existing file.
    }
  }
}

/// `YYYY-MM-DD HH:MM:SS` — a full wall-clock stamp for section headers/footers.
String logStamp(DateTime t) =>
    '${t.year}-${_pad2(t.month)}-${_pad2(t.day)} ${logClock(t)}';

/// `HH:MM:SS` — a compact clock stamp for per-line entries.
String logClock(DateTime t) =>
    '${_pad2(t.hour)}:${_pad2(t.minute)}:${_pad2(t.second)}';

/// A short human duration: `${m}m${s}s` past a minute, else `${s}s`.
String logDuration(Duration d) {
  final s = d.inSeconds;
  return s >= 60 ? '${s ~/ 60}m${s % 60}s' : '${s}s';
}

String _pad2(int n) => n.toString().padLeft(2, '0');
