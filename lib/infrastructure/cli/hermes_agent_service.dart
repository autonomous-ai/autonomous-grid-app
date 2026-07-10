import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host_environment.dart';

/// A handle to a running `hermes -z` one-shot: its stdout lines, its eventual
/// exit code, and a kill switch. Hermes prints the agent's answer as plain text
/// (no structured event stream like codex `--json`), so callers join the lines
/// into the reply.
class HermesRun {
  const HermesRun({
    required this.lines,
    required this.exitCode,
    required this.kill,
  });

  /// stdout lines, in arrival order.
  final Stream<String> lines;

  /// Completes with the process exit code (0 = success).
  final Future<int> exitCode;

  /// Sends SIGTERM (best effort) to the process.
  final void Function() kill;
}

/// The seam between the app and the `hermes` CLI — every hermes spawn goes
/// through here (the §7 rule that no feature runs `Process.run` ad-hoc). Behind
/// an interface so the Hermes-mode sender is tested against a fake that replays
/// scripted output, with no real process, network or model.
abstract interface class HermesAgentService {
  HermesRun run({
    required List<String> args,
    required Map<String, String> environment,
    required String workdir,
  });
}

/// Real implementation backed by `Process.start`, pinned to the resolved hermes
/// [_path] and the augmented [HostEnvironment.path] so a packaged GUI app finds
/// hermes's own dependencies its minimal inherited `PATH` would miss.
class HermesAgentServiceImpl implements HermesAgentService {
  const HermesAgentServiceImpl(this._path);

  final String _path;

  @override
  HermesRun run({
    required List<String> args,
    required Map<String, String> environment,
    required String workdir,
  }) {
    final controller = StreamController<String>();
    final exit = Completer<int>();
    Process? process;

    Future<void> pump() async {
      try {
        process = await Process.start(
          _path,
          args,
          workingDirectory: workdir,
          environment: {
            ...Platform.environment,
            'PATH': HostEnvironment.path(),
            ...environment,
          },
        );
      } on ProcessException {
        await controller.close();
        if (!exit.isCompleted) exit.complete(-1);
        return;
      }

      final stdoutDone = process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(controller.add);
      // Drain stderr so the process never blocks on a full pipe.
      final stderrDone = process!.stderr.transform(utf8.decoder).drain<void>();

      final code = await process!.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      await controller.close();
      if (!exit.isCompleted) exit.complete(code);
    }

    unawaited(pump());

    return HermesRun(
      lines: controller.stream,
      exitCode: exit.future,
      kill: () => process?.kill(),
    );
  }
}
