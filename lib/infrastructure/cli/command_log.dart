import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/app_log.dart';
import '../logging/http_log.dart';
import '../logging/log_file.dart';

/// How the command was issued: a `grid` CLI call (run/start/pull) or a direct
/// HTTP request (e.g. the Playground's local-provider smoke test).
enum CliCallKind { run, start, pull, http }

/// Lifecycle of a logged command.
enum CliCallStatus { running, success, failed }

/// Longest request/response body the Debug tab keeps. A media payload carries
/// base64 images and runs to megabytes; two hundred of those in the ring buffer
/// is the app's memory, not a debug aid. At this cap the buffer's worst case is
/// a few megabytes and its usual case a fraction of that. What gets dropped is
/// said out loud rather than trailing off, so nobody reads a cut body as whole.
const int kMaxLoggedBody = 8000;

/// [body] cut to [kMaxLoggedBody] characters, with a line naming what was left
/// out. Null in, null out.
String? clipLogBody(String? body) {
  if (body == null || body.length <= kMaxLoggedBody) return body;
  final dropped = body.length - kMaxLoggedBody;
  return '${body.substring(0, kMaxLoggedBody)}\n'
      '… $dropped more characters not kept';
}

/// The value for an `env` parameter: the **names** of the overrides that were
/// set, never their values. A value here is typically an API key — carrying it
/// through the environment instead of argv is the whole point of that channel,
/// and a debug panel that printed it would undo it.
String envParam(Map<String, String> environment) =>
    '${environment.keys.join(', ')} — values hidden';

/// Everything the one-line [GridCommandLog.command] leaves out, shown when a
/// row in the Debug tab is opened.
///
/// The list has to stay scannable, so a row is one line — and one line is
/// exactly what cannot hold the two things a failure is usually about: the
/// arguments as they were really passed, and the body that went over the wire.
/// Both live here instead.
///
/// Never carries a secret: env values are dropped at the call site (only their
/// names travel, via [envParam]) and request headers — where the bearer key
/// sits — are not recorded at all.
class CommandDetail {
  const CommandDetail({
    this.args = const [],
    this.params = const {},
    this.requestBody,
    this.responseBody,
  });

  /// Detail for a call whose request body is [body], encoded exactly the way it
  /// was sent. One place does the encoding so no call site hand-writes JSON that
  /// then drifts from the real payload.
  CommandDetail.json(Map<String, dynamic> body, {this.params = const {}})
    : args = const [],
      requestBody = jsonEncode(body),
      responseBody = null;

  /// One entry per argv token, so an argument containing spaces reads as the
  /// single argument it was and not as two words of a joined line.
  final List<String> args;

  /// Named inputs the summary line doesn't spell out — the model a turn ran, the
  /// folder it opened in, the names of the env vars that carried its secrets.
  final Map<String, String> params;

  /// The request payload as sent.
  final String? requestBody;

  /// What came back, when the caller has it — the assembled answer of a chat
  /// stream, say. Filled in at [CommandLogNotifier.finish].
  final String? responseBody;

  /// Whether there is anything to show beyond the summary line.
  bool get isEmpty =>
      args.isEmpty &&
      params.isEmpty &&
      requestBody == null &&
      responseBody == null;

  /// A copy with both bodies cut to [kMaxLoggedBody]. Applied centrally by
  /// [CommandLogNotifier] so no call site can forget it.
  CommandDetail clipped() => CommandDetail(
    args: args,
    params: params,
    requestBody: clipLogBody(requestBody),
    responseBody: clipLogBody(responseBody),
  );

  /// The same detail with [body] recorded as what came back.
  CommandDetail withResponse(String body) => CommandDetail(
    args: args,
    params: params,
    requestBody: requestBody,
    responseBody: clipLogBody(body),
  );
}

/// One command the app issued, captured for the Debug tab. Records the display
/// line, when it started, and how it ended (result code / error) — not the full
/// output, which the feature views already stream where it matters.
class GridCommandLog {
  const GridCommandLog({
    required this.id,
    required this.kind,
    required this.command,
    required this.startedAt,
    required this.status,
    this.exitCode,
    this.duration,
    this.error,
    this.detail = const CommandDetail(),
  });

  final int id;
  final CliCallKind kind;

  /// The command as a user would read it: `grid network status …` or
  /// `POST http://localhost:8081/v1/chat/completions`.
  final String command;
  final DateTime startedAt;
  final CliCallStatus status;

  /// Process exit code for CLI calls, HTTP status for [CliCallKind.http].
  final int? exitCode;
  final Duration? duration;
  final String? error;

  /// The arguments, parameters and bodies behind [command] — what the Debug
  /// tab's detail dialog shows.
  final CommandDetail detail;

  GridCommandLog copyWith({
    CliCallStatus? status,
    int? exitCode,
    Duration? duration,
    String? error,
    CommandDetail? detail,
  }) => GridCommandLog(
    id: id,
    kind: kind,
    command: command,
    startedAt: startedAt,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    duration: duration ?? this.duration,
    error: error ?? this.error,
    detail: detail ?? this.detail,
  );
}

/// In-memory ring buffer of recent commands, newest first. Fed by
/// [LoggingGridCliService] and the local-chat path; read by the Debug tab.
final commandLogProvider =
    NotifierProvider<CommandLogNotifier, List<GridCommandLog>>(
      CommandLogNotifier.new,
    );

class CommandLogNotifier extends Notifier<List<GridCommandLog>> {
  static const _maxEntries = 200;
  int _seq = 0;

  @override
  List<GridCommandLog> build() => const [];

  /// Records a command as it starts; returns its id for [finish].
  ///
  /// [detail] is the full argv / parameters / request body behind [command];
  /// its bodies are clipped here so a caller can hand over a payload of any
  /// size without thinking about it.
  int begin(
    CliCallKind kind,
    String command, {
    CommandDetail detail = const CommandDetail(),
  }) {
    final id = ++_seq;
    final entry = GridCommandLog(
      id: id,
      kind: kind,
      command: command,
      startedAt: DateTime.now(),
      status: CliCallStatus.running,
      detail: detail.clipped(),
    );
    // Write HTTP calls to their own durable file the instant they are issued —
    // not only when they complete — so a request that hangs still leaves a
    // trace. Synchronous and best-effort, so it never blocks the call.
    if (kind == CliCallKind.http) {
      ref.read(httpLogProvider).start(id, command);
    }
    _schedule(
      () => state = [entry, ...state].take(_maxEntries).toList(growable: false),
    );
    return id;
  }

  /// Marks a started command as finished. Failure = an [error], a non-zero exit
  /// (CLI), or a non-2xx status (HTTP). Also mirrors the completed call to the
  /// durable [appLogProvider] timeline so the same event survives an app close.
  ///
  /// [responseBody] is what came back, for the callers that hold it — it joins
  /// the entry's [CommandDetail] for the Debug tab's detail dialog.
  void finish(int id, {int? exitCode, String? error, String? responseBody}) {
    final endedAt = DateTime.now();
    _schedule(() {
      GridCommandLog? finished;
      state = [
        for (final e in state)
          if (e.id == id)
            finished = e.copyWith(
              status: _failed(e.kind, exitCode, error)
                  ? CliCallStatus.failed
                  : CliCallStatus.success,
              exitCode: exitCode,
              duration: endedAt.difference(e.startedAt),
              error: error,
              detail: responseBody == null
                  ? null
                  : e.detail.withResponse(responseBody),
            )
          else
            e,
      ];
      if (finished != null) {
        _mirrorToAppLog(finished);
        if (finished.kind == CliCallKind.http) {
          ref
              .read(httpLogProvider)
              .finish(
                finished.id,
                statusCode: finished.exitCode,
                error: finished.error,
                duration: finished.duration,
              );
        }
      }
    });
  }

  /// Append a one-line summary of a completed command to the app-log timeline:
  /// `grid --remote login → ok exit=0 (4s)` (CLI) or a `FAILED` line at error
  /// level. HTTP calls are tagged `api`, everything else `cli`.
  void _mirrorToAppLog(GridCommandLog e) {
    final appLog = ref.read(appLogProvider);
    final isHttp = e.kind == CliCallKind.http;
    final failed = e.status == CliCallStatus.failed;
    final code = e.exitCode == null
        ? ''
        : isHttp
        ? ' status=${e.exitCode}'
        : ' exit=${e.exitCode}';
    final dur = e.duration == null ? '' : ' (${logDuration(e.duration!)})';
    final err = e.error == null ? '' : ': ${e.error}';
    final message = '${e.command} → ${failed ? 'FAILED' : 'ok'}$code$dur$err';
    final category = isHttp ? 'api' : 'cli';
    failed ? appLog.failure(category, message) : appLog.info(category, message);
  }

  static bool _failed(CliCallKind kind, int? code, String? error) {
    if (error != null) return true;
    if (code == null) return false;
    return kind == CliCallKind.http ? code < 200 || code >= 300 : code != 0;
  }

  void clear() => _schedule(() => state = const []);

  /// Applies a state mutation on the next microtask, never synchronously. A CLI
  /// call can be kicked off from inside another provider's build (e.g.
  /// preflight), and Riverpod forbids mutating a provider during another's
  /// initialization — deferring sidesteps that without losing ordering.
  void _schedule(void Function() update) => Future.microtask(update);
}
