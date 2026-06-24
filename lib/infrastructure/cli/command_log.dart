import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How the command was issued: a `grid` CLI call (run/start/pull) or a direct
/// HTTP request (e.g. the Playground's local-provider smoke test).
enum CliCallKind { run, start, pull, http }

/// Lifecycle of a logged command.
enum CliCallStatus { running, success, failed }

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

  GridCommandLog copyWith({
    CliCallStatus? status,
    int? exitCode,
    Duration? duration,
    String? error,
  }) =>
      GridCommandLog(
        id: id,
        kind: kind,
        command: command,
        startedAt: startedAt,
        status: status ?? this.status,
        exitCode: exitCode ?? this.exitCode,
        duration: duration ?? this.duration,
        error: error ?? this.error,
      );
}

/// In-memory ring buffer of recent commands, newest first. Fed by
/// [LoggingGridCliService] and the local-chat path; read by the Debug tab.
final commandLogProvider =
    NotifierProvider<CommandLogNotifier, List<GridCommandLog>>(
        CommandLogNotifier.new);

class CommandLogNotifier extends Notifier<List<GridCommandLog>> {
  static const _maxEntries = 200;
  int _seq = 0;

  @override
  List<GridCommandLog> build() => const [];

  /// Records a command as it starts; returns its id for [finish].
  int begin(CliCallKind kind, String command) {
    final id = ++_seq;
    final entry = GridCommandLog(
      id: id,
      kind: kind,
      command: command,
      startedAt: DateTime.now(),
      status: CliCallStatus.running,
    );
    _schedule(() =>
        state = [entry, ...state].take(_maxEntries).toList(growable: false));
    return id;
  }

  /// Marks a started command as finished. Failure = an [error], a non-zero exit
  /// (CLI), or a non-2xx status (HTTP).
  void finish(int id, {int? exitCode, String? error}) {
    final endedAt = DateTime.now();
    _schedule(() {
      state = [
        for (final e in state)
          if (e.id == id)
            e.copyWith(
              status: _failed(e.kind, exitCode, error)
                  ? CliCallStatus.failed
                  : CliCallStatus.success,
              exitCode: exitCode,
              duration: endedAt.difference(e.startedAt),
              error: error,
            )
          else
            e,
      ];
    });
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
