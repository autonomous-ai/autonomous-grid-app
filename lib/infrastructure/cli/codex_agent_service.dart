import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'codex_event.dart';
import 'host_environment.dart';

/// A handle to a running `codex exec --json` process: its parsed event stream,
/// its eventual exit code, and a kill switch. Mirrors `GridProcess` so the Agent
/// path has the same shape as every other app-owned process.
class CodexRun {
  const CodexRun({
    required this.events,
    required this.exitCode,
    required this.kill,
  });

  /// Structured events parsed from stdout JSONL, in arrival order.
  final Stream<CodexEvent> events;

  /// Completes with the process exit code (0 = success).
  final Future<int> exitCode;

  /// Sends SIGTERM (best effort) to the process.
  final void Function() kill;
}

/// The seam between the app and the `codex` CLI — every codex spawn goes through
/// here (the §7 rule that no feature runs `Process.run` ad-hoc). Behind an
/// interface so the Agent-mode sender can be tested against a fake that emits a
/// scripted event stream, with no real process, network or model.
abstract interface class CodexAgentService {
  /// Runs `codex exec` with [args] in [workdir], with [environment] merged on
  /// top of the augmented host environment (the channel for the grid API key,
  /// kept out of argv so it never lands in a log).
  CodexRun exec({
    required List<String> args,
    required Map<String, String> environment,
    required String workdir,
  });
}

/// Real implementation backed by `Process.start`. Pinned to the resolved codex
/// [_codexPath] and the augmented [HostEnvironment.path] so a packaged GUI app
/// finds codex's own dependencies (e.g. `ripgrep`) that its minimal inherited
/// `PATH` would miss.
class CodexAgentServiceImpl implements CodexAgentService {
  const CodexAgentServiceImpl(this._codexPath);

  final String _codexPath;

  @override
  CodexRun exec({
    required List<String> args,
    required Map<String, String> environment,
    required String workdir,
  }) {
    final controller = StreamController<CodexEvent>();
    final exit = Completer<int>();
    Process? process;

    Future<void> pump() async {
      try {
        process = await Process.start(
          _codexPath,
          args,
          workingDirectory: workdir,
          environment: {
            ...Platform.environment,
            'PATH': HostEnvironment.path(),
            ...environment,
          },
        );
      } on ProcessException catch (e) {
        controller.add(CodexStreamError(e.message));
        await controller.close();
        exit.complete(-1);
        return;
      }

      final stdoutDone = process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            final event = parseCodexEvent(line);
            if (event != null) controller.add(event);
          });
      // Drain stderr so the process never blocks on a full pipe; codex logs
      // human text there, not events, so it isn't parsed.
      final stderrDone = process!.stderr.transform(utf8.decoder).drain<void>();

      final code = await process!.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      await controller.close();
      if (!exit.isCompleted) exit.complete(code);
    }

    unawaited(pump());

    return CodexRun(
      events: controller.stream,
      exitCode: exit.future,
      kill: () => process?.kill(),
    );
  }
}
