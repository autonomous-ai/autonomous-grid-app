import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log_file.dart';

/// Severity of an [AppLog] event, in ascending order.
enum AppLogLevel { debug, info, warn, error }

/// The app's own diagnostic logger — a durable, human-readable timeline written
/// to `~/.grid/logs/app.log`.
///
/// Why: the app's flow and its failures otherwise live only in the console,
/// which a shipped desktop build has no one watching. This leaves a file we can
/// ask a user to send us to see what the app did (lifecycle, each CLI/HTTP call)
/// and exactly where it broke (uncaught errors with stack traces).
///
/// [category] is a short, stable tag grouping related events — `app` (lifecycle),
/// `api` (HTTP), `cli` (command summaries), `flutter` (framework errors) — so the
/// timeline can be skimmed or filtered by concern.
abstract interface class AppLog {
  /// Append one structured event. [error]/[stackTrace] are included when present
  /// (the stack trace is indented on following lines).
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });
}

/// Level-named conveniences over [AppLog.record], kept as extensions so every
/// [AppLog] implementation gets them for free without re-declaring the surface.
extension AppLogX on AppLog {
  void debug(String category, String message) =>
      record(AppLogLevel.debug, category, message);

  void info(String category, String message) =>
      record(AppLogLevel.info, category, message);

  void warn(String category, String message, {Object? error}) =>
      record(AppLogLevel.warn, category, message, error: error);

  void failure(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => record(
    AppLogLevel.error,
    category,
    message,
    error: error,
    stackTrace: stackTrace,
  );
}

/// [AppLog] backed by a per-day file under `~/.grid/logs` (`app-YYYYMMDD.log`).
/// Writes are synchronous and flushed (see [DailyLogFile]); IO errors are
/// swallowed — logging must never break the flow it observes.
class FileAppLog implements AppLog {
  FileAppLog(this._file);

  final DailyLogFile _file;

  @override
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final line = StringBuffer(
      '[${logStamp(DateTime.now())}] '
      '${_levelTag(level)} ${_categoryTag(category)} $message',
    );
    if (error != null) line.write('  err=$error');
    _file.append(line.toString());
    if (stackTrace != null) {
      _file.append(
        stackTrace
            .toString()
            .trimRight()
            .split('\n')
            .map((l) => '    $l')
            .join('\n'),
      );
    }
  }

  /// Five-wide upper-case level so message columns line up.
  static String _levelTag(AppLogLevel level) => switch (level) {
    AppLogLevel.debug => 'DEBUG',
    AppLogLevel.info => 'INFO ',
    AppLogLevel.warn => 'WARN ',
    AppLogLevel.error => 'ERROR',
  };

  /// Pad short categories to a common width for a readable second column.
  static String _categoryTag(String category) =>
      category.length >= 7 ? category : category.padRight(7);
}

/// No-op [AppLog] used by default (and in tests) so nothing touches `~/.grid`
/// until the app explicitly wires a [FileAppLog] at its composition root.
class NoopAppLog implements AppLog {
  const NoopAppLog();

  @override
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {}
}

/// The app-log sink. Defaults to [NoopAppLog] so unit tests stay offline; the
/// app overrides it with a [FileAppLog] in its root `ProviderScope` (see
/// `main.dart`) so every consumer shares the one file instance.
final appLogProvider = Provider<AppLog>((ref) => const NoopAppLog());
