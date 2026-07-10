import 'dart:io';

/// Best-effort append-only diagnostic log split into one file per calendar day
/// (`<base>-YYYYMMDD.log`) inside a directory.
///
/// Why per-day: a single ever-growing file eventually becomes too big to open or
/// send us, and the old size-based `.old` rotation kept only the last slice.
/// Dating the file caps each day's size on its own and lets us prune anything
/// past [retentionDays] automatically, so the logs directory stays bounded
/// without ever discarding the current session.
///
/// Writes are synchronous and flushed so a line survives even if the app is
/// force-quit mid-write, and every IO error is swallowed — diagnostic logging
/// must never break the flow it only observes. Shared low-level sink behind
/// [FileAppLog], [FileCliLog] and [FileNodeSetupLog] so the append/prune rules
/// live in exactly one place.
class DailyLogFile {
  DailyLogFile(
    this.directory,
    this.base, {
    this.retentionDays = 14,
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock;

  /// Directory holding the dated files (`~/.grid/logs`). Created on demand.
  final Directory directory;

  /// Filename stem shared by every day's file — `app` → `app-YYYYMMDD.log`.
  final String base;

  /// Keep at most this many days of this base's files; older ones are deleted
  /// the first time a new day is written. A value `<= 0` disables pruning.
  final int retentionDays;

  final DateTime Function() _clock;

  /// `YYYYMMDD` of the file we last wrote, so pruning only runs when the day
  /// actually rolls over — not on every append.
  String? _activeDay;

  /// The file the next [append] would write to, for the current wall-clock day.
  /// Exposed so callers (and tests) can read back what was just written.
  File get currentFile => _fileFor(_clock());

  File _fileFor(DateTime day) =>
      File('${directory.path}/${dailyLogName(base, day)}');

  /// Append [block] followed by a newline to today's file. Creates the directory
  /// on demand and prunes stale days on the first write after midnight; any
  /// failure is swallowed.
  void append(String block) {
    try {
      final now = _clock();
      final day = _ymd(now);
      final file = _fileFor(now);
      file.parent.createSync(recursive: true);
      if (day != _activeDay) {
        _activeDay = day;
        _pruneOlderThan(now);
      }
      file.writeAsStringSync('$block\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort: never surface an IO failure into the caller's flow.
    }
  }

  /// Delete this base's dated files older than [retentionDays] before [now].
  void _pruneOlderThan(DateTime now) {
    if (retentionDays <= 0) return;
    try {
      final cutoff = _ymd(now.subtract(Duration(days: retentionDays)));
      final prefix = '$base-';
      for (final entry in directory.listSync()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith(prefix) || !name.endsWith('.log')) continue;
        final day = name.substring(prefix.length, name.length - 4);
        if (day.length == 8 &&
            int.tryParse(day) != null &&
            day.compareTo(cutoff) < 0) {
          entry.deleteSync();
        }
      }
    } catch (_) {
      // Pruning is best-effort; on failure the old files simply stay put.
    }
  }
}

/// The dated filename for [base] on [day]: `app` → `app-20260710.log`.
String dailyLogName(String base, DateTime day) => '$base-${_ymd(day)}.log';

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

/// `YYYYMMDD` — the compact calendar-day stamp used in daily log filenames.
String _ymd(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}${_pad2(t.month)}${_pad2(t.day)}';

String _pad2(int n) => n.toString().padLeft(2, '0');
