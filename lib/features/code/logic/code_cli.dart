import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'code_errors.dart';
import 'task_event.dart';

/// How long the slow commands are given, each for a measured reason.
///
/// Finishing an import makes the relay read every tree the pushed history
/// reaches — 18s on a 29,000-commit repository, under its own 600s ceiling —
/// and the CLI waits 900s for it deliberately, because a client that gives up
/// first turns a refusal into "the connection died" and the import either
/// lands unobserved or does not, with no way to tell from here. The app sits
/// above the CLI for the same reason.
const kImportTimeout = Duration(minutes: 20);

/// A clone and a fetch are git transfers over the relay's own front. Minutes on
/// a real repository, and nothing is corrupted by waiting.
const kTransferTimeout = Duration(minutes: 10);

/// The one seam between this feature and the `grid` binary.
///
/// Every call goes through [GridCliService], which is already wrapped in remote
/// mode, the Debug tab's recorder and the durable transcript — so nothing here
/// spawns a process of its own or logs a second copy.
class CodeCli {
  const CodeCli(this._service);

  final GridCliService _service;

  /// Run a `--json` command and decode its object reply.
  ///
  /// Throws [CodeCliTooOld] when this build of `grid` has no such command, and
  /// [CodeGridException] for everything else — the CLI's own sentence, which is
  /// usually already the right thing to show.
  Future<Map<String, dynamic>> object(
    List<String> args, {
    Duration? timeout,
  }) async {
    final result = await _service.run(args, timeout: timeout);
    if (cliLacksCodeCommands(result)) throw const CodeCliTooOld();
    if (!result.ok) {
      throw CodeGridException(
        friendlyCodeError(result),
        raw: result.errorMessage,
      );
    }
    final decoded = _decode(result.stdout);
    if (decoded == null) {
      // A reply this app cannot read is not a result. Every handler in this
      // plane follows the rule, and it is what stops a body a proxy stripped
      // from being reported as work that landed.
      throw CodeGridException(
        'The grid answered in a way this app could not read. The command log '
        'has what it sent.',
        raw: result.stdout,
      );
    }
    return decoded;
  }

  /// Whether this build of `grid` knows the shared-project commands at all.
  ///
  /// Asked once, with `--help`, so a screen can offer an update instead of
  /// letting every action fail with argparse's list of the commands it *does*
  /// have. `--help` is answered during parsing, so it costs no network.
  Future<bool> supportsCodeCommands() async {
    final result = await _service.run(['task', '--help']);
    return result.ok;
  }

  /// Watch a task while it runs: one event per line until a terminal one.
  ///
  /// The stream ends when the CLI's own process does. **A non-zero exit is not
  /// a failure here** — `grid task follow` exits 1 for a task that *failed*,
  /// which is a perfectly well-delivered answer — so the outcome is read from
  /// [TaskTerminal] and never from the exit code.
  ///
  /// Cancelling the subscription kills the process, so closing a task's screen
  /// does not leave a `grid` running for the rest of the session.
  Stream<TaskEvent> follow(List<String> args) {
    late final StreamController<TaskEvent> controller;
    GridProcess? process;
    StreamSubscription<CliLine>? lines;

    Future<void> begin() async {
      try {
        process = await _service.start(args);
      } on Object catch (error, stack) {
        if (!controller.isClosed) controller.addError(error, stack);
        if (!controller.isClosed) await controller.close();
        return;
      }
      lines = process!.lines.listen(
        (line) {
          // stderr carries the CLI's own diagnostics (a reconnect notice, a
          // capacity warning). They are not events, and parsing them as such
          // would be guesswork — the event stream is stdout alone.
          if (line.isStderr) return;
          final event = parseTaskEvent(line.text);
          if (event != null && !controller.isClosed) controller.add(event);
        },
        onError: (Object error, StackTrace stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        },
        onDone: () async {
          if (!controller.isClosed) await controller.close();
        },
      );
    }

    controller = StreamController<TaskEvent>(
      onListen: () => unawaited(begin()),
      onCancel: () async {
        await lines?.cancel();
        process?.kill();
      },
    );
    return controller.stream;
  }

  static Map<String, dynamic>? _decode(String stdout) {
    final text = stdout.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }
}

/// Never retry a command that failed.
///
/// Riverpod retries a failed provider **ten times** by default, and every one
/// of these is a process spawn against a grid that already answered. Measured
/// on a live relay predating the projects plane: one screen produced six
/// `grid project list` calls in nine seconds, each refused with the same
/// sentence, and the tenth would have said it too.
///
/// A refusal here is a verdict — the relay is too old, the session expired,
/// this member is not in the project — and no amount of asking again changes
/// one. What recovers instead is deliberate: the status and task lists carry
/// their own poll timers, and everything else is one visible Retry away. That
/// also keeps the failure on screen where somebody can read it, rather than
/// behind a spinner that churns for half a minute first.
Duration? neverRetryCodeCommand(int attempt, Object error) => null;

/// The feature's CLI seam. Null when `grid` cannot be found at all — the same
/// gate the rest of the app already stands behind.
final codeCliProvider = Provider<CodeCli?>((ref) {
  final service = ref.watch(gridCliServiceProvider);
  return service == null ? null : CodeCli(service);
});

/// Whether the installed `grid` has the shared-project commands.
///
/// Probed once per launch rather than assumed from a version number: the
/// commands arrived without one changing, so the version says nothing.
final codeCliSupportedProvider = FutureProvider<bool>(
  retry: neverRetryCodeCommand,
  (ref) async {
    final cli = ref.watch(codeCliProvider);
    if (cli == null) return false;
    return cli.supportsCodeCommands();
  },
);

/// The CLI seam, or a clean refusal. Every controller here needs it and none of
/// them can do anything useful without it, so the check lives in one place.
CodeCli requireCodeCli(Ref ref) {
  final cli = ref.read(codeCliProvider);
  if (cli == null) {
    throw const CodeGridException(
      "The grid tool isn't available on this computer.",
    );
  }
  return cli;
}
