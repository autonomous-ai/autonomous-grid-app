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

/// The tail [clipLogBody] leaves on a body it had to cut. Read back by
/// [isClippedBody], so a copied `curl` can warn that its `-d` is not the whole
/// payload rather than quietly sending a truncated one.
const String kClippedBodyNote = 'more characters not kept';

/// [body] cut to [kMaxLoggedBody] characters, with a line naming what was left
/// out. Null in, null out.
String? clipLogBody(String? body) {
  if (body == null || body.length <= kMaxLoggedBody) return body;
  final dropped = body.length - kMaxLoggedBody;
  return '${body.substring(0, kMaxLoggedBody)}\n'
      '… $dropped $kClippedBodyNote';
}

/// Whether [body] is one [clipLogBody] shortened.
bool isClippedBody(String body) => body.endsWith(kClippedBodyNote);

/// Everything the one-line [GridCommandLog.command] leaves out, shown when a
/// row in the Debug tab is opened.
///
/// The list has to stay scannable, so a row is one line — and one line is
/// exactly what cannot hold the two things a failure is usually about: the
/// arguments as they were really passed, and the body that went over the wire.
/// Both live here instead, in the form a terminal would take them: the argv is
/// whole (program included) and the body is the bytes that were sent, so the
/// panel can hand back a command that runs.
///
/// Never carries a secret: of the environment only [envKeys] travels, and
/// request headers — where the bearer key sits — are not recorded at all.
class CommandDetail {
  const CommandDetail({
    this.args = const [],
    this.params = const {},
    this.envKeys = const [],
    this.requestBody,
    this.responseBody,
    this.authorized = false,
  });

  /// Detail for a call whose request body is [body], encoded exactly the way it
  /// was sent. One place does the encoding so no call site hand-writes JSON that
  /// then drifts from the real payload.
  ///
  /// [authorized] records *that* the request carried a bearer token, never
  /// which — enough for a copied `curl` to include the header with a shell
  /// variable in place of the key.
  CommandDetail.json(
    Map<String, dynamic> body, {
    this.params = const {},
    this.authorized = false,
  }) : args = const [],
       envKeys = const [],
       requestBody = jsonEncode(body),
       responseBody = null;

  /// The full argv, program first (`['grid', '--remote', 'sync']`) — one entry
  /// per token, so an argument containing spaces reads as the single argument
  /// it was and can be re-quoted when the command is copied.
  final List<String> args;

  /// Named inputs the summary line doesn't spell out — the folder a turn opened
  /// in, a URL's query string.
  final Map<String, String> params;

  /// Names of the environment overrides the command was given. **Names only**: a
  /// value here is typically an API key, and carrying it through the environment
  /// instead of argv is the whole point of that channel.
  final List<String> envKeys;

  /// The request payload as sent.
  final String? requestBody;

  /// What came back, when the caller has it — the assembled answer of a chat
  /// stream, say. Filled in at [CommandLogNotifier.finish].
  final String? responseBody;

  /// Whether the request carried an `Authorization` header.
  final bool authorized;

  /// Whether there is anything to show beyond the summary line.
  bool get isEmpty =>
      args.isEmpty &&
      params.isEmpty &&
      envKeys.isEmpty &&
      requestBody == null &&
      responseBody == null;

  /// A copy with both bodies cut to [kMaxLoggedBody]. Applied centrally by
  /// [CommandLogNotifier] so no call site can forget it.
  CommandDetail clipped() => _copy(
    requestBody: clipLogBody(requestBody),
    responseBody: clipLogBody(responseBody),
  );

  /// The same detail with [body] recorded as what came back.
  CommandDetail withResponse(String body) =>
      _copy(requestBody: requestBody, responseBody: clipLogBody(body));

  CommandDetail _copy({
    required String? requestBody,
    required String? responseBody,
  }) => CommandDetail(
    args: args,
    params: params,
    envKeys: envKeys,
    requestBody: requestBody,
    responseBody: responseBody,
    authorized: authorized,
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
  ///
  /// The deferral is also what makes the [ref.mounted] check necessary: between
  /// scheduling and running, the provider can be disposed — a grid closed while
  /// its overview poll is still on the wire, which is exactly what
  /// `gridOverviewForProvider` does on teardown. Writing `state` then throws
  /// "Cannot use the Ref ... after it has been disposed", and the throw lands in
  /// a microtask with no caller to catch it: it took down six unrelated tests
  /// and would, in the app, surface as an unhandled error from a log line
  /// nobody was reading.
  void _schedule(void Function() update) => Future.microtask(() {
    if (!ref.mounted) return;
    update();
  });
}
