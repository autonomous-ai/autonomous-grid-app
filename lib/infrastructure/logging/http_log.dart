import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import 'log_file.dart';

/// Durable, append-only transcript of every HTTP request the app makes, written
/// per day to `~/.grid/logs/app_https-YYYYMMDD.log`.
///
/// Why a dedicated file: HTTP is the app's main network surface (relay chat and
/// media, the managed-grid API), and a user debugging "chat won't answer" or
/// "the grid says offline" wants exactly those requests without wading through
/// the CLI transcript. The `→` line is written the moment the request is issued
/// — not only when it completes — so even a call that hangs or crashes the app
/// still leaves a "started" trace on disk. Each request is tagged with the
/// command log's id (`#3`) so its start and outcome lines stay correlated when
/// concurrent calls interleave.
abstract interface class HttpLog {
  /// Record that request [id] has just been issued. [request] is the display
  /// line (`POST https://…/v1/chat/completions`). Written immediately.
  void start(int id, String request);

  /// Record how request [id] ended: HTTP [statusCode] or an [error], plus how
  /// long it took.
  void finish(int id, {int? statusCode, String? error, Duration? duration});
}

/// [HttpLog] backed by a per-day file under `~/.grid/logs`
/// (`app_https-YYYYMMDD.log`). Writes are synchronous and flushed (see
/// [DailyLogFile]); IO errors are swallowed — logging must never break the
/// request it observes.
class FileHttpLog implements HttpLog {
  FileHttpLog(this._file);

  final DailyLogFile _file;

  @override
  void start(int id, String request) =>
      _file.append('[${logClock(DateTime.now())}] #$id → $request');

  @override
  void finish(int id, {int? statusCode, String? error, Duration? duration}) {
    final failed =
        error != null ||
        (statusCode != null && (statusCode < 200 || statusCode >= 300));
    final status = statusCode == null ? '' : ' status=$statusCode';
    final took = duration == null ? '' : ' (${logDuration(duration)})';
    final err = error == null ? '' : ': $error';
    _file.append(
      '[${logClock(DateTime.now())}] #$id '
      '← ${failed ? 'FAILED' : 'ok'}$status$took$err',
    );
  }
}

/// No-op [HttpLog] used by default (and in tests) so nothing touches `~/.grid`
/// until the app wires a [FileHttpLog] at its composition root (see `main.dart`).
class NoopHttpLog implements HttpLog {
  const NoopHttpLog();

  @override
  void start(int id, String request) {}

  @override
  void finish(int id, {int? statusCode, String? error, Duration? duration}) {}
}

/// The HTTP transcript sink. Defaults to [NoopHttpLog] so unit tests stay
/// offline; the app overrides it with a [FileHttpLog] in its root
/// `ProviderScope`. Fed centrally by [CommandLogNotifier], so every HTTP call
/// the app already reports lands here with no per-call-site wiring.
final httpLogProvider = Provider<HttpLog>((ref) => const NoopHttpLog());

/// Builds the real per-day HTTP file sink under `~/.grid/logs`. Called from
/// `main.dart` to override [httpLogProvider].
FileHttpLog buildFileHttpLog() =>
    FileHttpLog(DailyLogFile(GridPaths.logsDir, GridPaths.httpLogBase));
