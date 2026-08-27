import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/app_environment.dart';
import 'grid_cli_service.dart';
import 'host_environment.dart';
import 'parsers/download_progress.dart';

/// Real implementation that spawns the `grid` binary. Always argv form
/// (`runInShell: false`) — never string interpolation into a shell — to avoid
/// command injection (CLI_Integration_Contract §2).
class GridCliServiceImpl implements GridCliService {
  GridCliServiceImpl(this.executable) : _env = _buildEnv();

  /// Absolute path to `grid`, from [GridResolver].
  final String executable;

  /// Environment for spawned `grid` processes:
  /// - `PYTHONUNBUFFERED` so the piped Python CLI flushes stdout per line —
  ///   without it, streamed output (e.g. the device-login URL) is withheld
  ///   until the process exits, which it doesn't while polling.
  /// - `PYTHONUTF8` / `PYTHONIOENCODING` force UTF-8 I/O. A Finder-launched GUI
  ///   app inherits no `LANG`, so the frozen Python `grid` would otherwise pick
  ///   ASCII stdio and crash with `UnicodeEncodeError` the moment it prints a
  ///   non-ASCII char (e.g. the "–"/"—" in its own messages) — failing install,
  ///   joining an engine, etc. with exit 1.
  /// - an augmented `PATH` (+ a UTF-8 `LANG`) so `grid`'s own children (brew,
  ///   docker, cmake, llama-server) resolve and also emit UTF-8 — a GUI app
  ///   inherits only a minimal environment. The `PATH` comes from
  ///   [HostEnvironment], shared with the app's own tool detection so they agree.
  /// - in dev only, any `GRID_CONTROL_PLANE_URL`/`GRID_WEBSITE_URL` staging
  ///   overrides from [AppEnvironment], so the CLI hits the same backend as the
  ///   app. Empty in release builds (which always use prod).
  final Map<String, String> _env;

  static Map<String, String> _buildEnv() {
    final env = <String, String>{
      'PYTHONUNBUFFERED': '1',
      'PYTHONUTF8': '1',
      'PYTHONIOENCODING': 'utf-8',
    };
    if (!Platform.isWindows) {
      env['PATH'] = HostEnvironment.path();
      // Keep the user's locale when present; otherwise give children a sane
      // UTF-8 default instead of the C/POSIX (ASCII) locale.
      final lang = Platform.environment['LANG'];
      env['LANG'] = (lang != null && lang.isNotEmpty) ? lang : 'en_US.UTF-8';
    }
    env.addAll(AppEnvironment.cliEnvOverrides());
    return env;
  }

  /// Upper bound on a one-shot `grid` command. These are quick lifecycle calls
  /// (login/logout/leave/sync/catalog), not streams, so a wait past this means
  /// the CLI is wedged — return a failed result rather than hang a caller (and
  /// through it, screens gated on it like preflight) forever.
  static const _runTimeout = Duration(seconds: 60);

  /// Stand-in for a process that never reported one. Read [CliResult.outcome],
  /// not this, to tell the two no-exit cases apart.
  static const _noExitCode = -1;

  @override
  Future<CliResult> run(List<String> args, {Duration? timeout}) async {
    try {
      final result = await Process.run(
        executable,
        args,
        runInShell: false,
        environment: _env,
      ).timeout(timeout ?? _runTimeout);
      return CliResult(
        exitCode: result.exitCode,
        stdout: result.stdout as String,
        stderr: result.stderr as String,
      );
    } on TimeoutException {
      return const CliResult(
        exitCode: _noExitCode,
        stdout: '',
        stderr: 'grid command timed out.',
        outcome: CliOutcome.timedOut,
      );
    } on ProcessException catch (e) {
      // The binary resolved but the OS refused to start it — a deleted sidecar,
      // a permissions problem, or an executable built for another CPU (an Intel
      // DMG on an Apple Silicon Mac with no Rosetta). Uncaught, this threw
      // straight out of the preflight provider and put the raw exception on
      // screen; a failed result lets callers say something a user can act on.
      return CliResult(
        exitCode: _noExitCode,
        stdout: '',
        stderr: e.message,
        outcome: CliOutcome.spawnFailed,
      );
    }
  }

  @override
  Future<GridProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    // Per-call vars (e.g. an API-engine key) layer on top of the base env, never
    // replacing it — the CLI still needs PATH/PYTHONUNBUFFERED/UTF-8 to run.
    final env = (environment == null || environment.isEmpty)
        ? _env
        : {..._env, ...environment};
    final process = await Process.start(
      executable,
      args,
      runInShell: false,
      environment: env,
    );
    final controller = StreamController<CliLine>();

    final outSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => controller.add(CliLine(isStderr: false, text: line)),
          onError: controller.addError,
        );
    final errSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => controller.add(CliLine(isStderr: true, text: line)),
          onError: controller.addError,
        );

    unawaited(
      process.exitCode.whenComplete(() async {
        await outSub.cancel();
        await errSub.cancel();
        await controller.close();
      }),
    );

    return GridProcess(
      lines: controller.stream,
      exitCode: process.exitCode,
      kill: () => process.kill(ProcessSignal.sigterm),
    );
  }

  @override
  Stream<DownloadProgress> pull(List<String> args) {
    // Built around a StreamController so cancelling the subscription (the user
    // hitting "Cancel") can SIGTERM the `grid pull` process — the transfer
    // actually stops instead of running on in the background.
    Process? process;
    StreamSubscription<String>? stderrSub;
    late final StreamController<DownloadProgress> controller;
    // Set by onCancel, so the SIGTERM we sent ourselves isn't reported to the
    // user as a download that failed.
    var cancelled = false;
    // The last stderr that wasn't a progress frame — `grid pull` prints its
    // reason there and exits non-zero ("Download failed (404): …"). Kept so the
    // error carries it instead of a shrug; collecting stderr and never reading
    // it is how a 404 came to look like a completed download.
    var lastMessage = '';
    // Completes when stderr can produce nothing more — drained, errored, or
    // cancelled. Every one of those has to settle it: the exit handler waits on
    // it, and a wait that never ends would leave the controller open forever.
    final stderrDone = Completer<void>();
    void settleStderr() {
      if (!stderrDone.isCompleted) stderrDone.complete();
    }

    Future<void> begin() async {
      try {
        process = await Process.start(
          executable,
          args,
          runInShell: false,
          environment: _env,
        );
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
        if (!controller.isClosed) await controller.close();
        return;
      }
      // Progress is written with `\r`, so decode bytes and split on it ourselves
      // rather than using a line splitter (which only breaks on `\n`).
      stderrSub = process!.stderr
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              final progress = DownloadProgress.latest(chunk);
              if (progress == null) {
                final text = chunk.trim();
                if (text.isNotEmpty) lastMessage = text;
                return;
              }
              if (!controller.isClosed) controller.add(progress);
            },
            onError: (Object e, StackTrace st) {
              settleStderr();
              if (!controller.isClosed) controller.addError(e, st);
            },
            onDone: settleStderr,
            cancelOnError: true,
          );
      unawaited(
        process!.exitCode.then((code) async {
          // Wait for stderr to drain before judging: the reason for a failure
          // is usually still in flight when the process itself is gone.
          await stderrDone.future;
          if (!controller.isClosed && !cancelled && code != 0) {
            controller.addError(
              GridPullFailed(exitCode: code, message: lastMessage),
              StackTrace.current,
            );
          }
          if (!controller.isClosed) await controller.close();
        }),
      );
    }

    controller = StreamController<DownloadProgress>(
      onListen: () => unawaited(begin()),
      onCancel: () async {
        cancelled = true;
        process?.kill(ProcessSignal.sigterm);
        await stderrSub?.cancel();
        settleStderr();
      },
    );
    return controller.stream;
  }
}
