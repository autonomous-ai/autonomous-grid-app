import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/logic/adapters/hermes_tool.dart';
import '../logging/app_log.dart';
import 'hermes_gateway_service.dart';

/// How long a scheduled run may go without a sign of life before Hermes's
/// scheduler kills it, in seconds — read from `~/.hermes/.env`.
///
/// It is an *inactivity* limit, not a time limit: a task that keeps calling
/// tools can run for hours. There is no key for it in `config.yaml` (unlike the
/// chat gateway's `agent.gateway_timeout`), so this env var is the only way to
/// change it.
const String kCronIdleLimitVar = 'HERMES_CRON_TIMEOUT';

/// The limit the app asks for: 45 minutes of silence, up from Hermes's 600s.
///
/// A scheduled run is forced down Hermes's **non-streaming** path (its agent
/// takes it whenever `platform == "cron"`), so nothing touches the activity
/// clock between sending a prompt and receiving the whole answer — a long
/// report on a slow model runs the clock from zero for the entire generation.
/// Ten minutes is comfortably less than that takes on a grid model, and the run
/// dies mid-answer with the day's work lost. Not unlimited: a genuinely wedged
/// provider still has to be caught, or the task hangs until the machine is
/// rebooted.
const int kCronIdleLimitSeconds = 2700;

/// The seam onto the idle limit, or null when there's no agent installed — no
/// scheduler to raise a limit on.
final hermesCronWatchdogProvider = Provider<HermesCronWatchdog?>((ref) {
  final path = ref.watch(hermesPathProvider);
  if (path == null) return null;
  return HermesCronWatchdog(
    HermesGatewayServiceImpl(path),
    log: ref.watch(appLogProvider),
  );
});

/// What to write into `~/.hermes/.env` to raise the scheduler's idle limit, or
/// null when there is nothing to write.
///
/// A value already in the file is left alone even when it's lower than ours:
/// whoever typed it chose it, and silently overwriting somebody's own limit is
/// how an app earns a reputation for editing files behind your back. A blank
/// assignment is *not* a choice — Hermes reads it as unset and falls back to its
/// own 600s — so that one is filled in.
///
/// Pure, so the rule that decides whether the app edits a user's file is
/// unit-tested rather than only observed on a machine that already has the key.
Map<String, String>? cronIdleLimitUpdate(Map<String, String> env) =>
    (env[kCronIdleLimitVar] ?? '').trim().isNotEmpty
    ? null
    : const {kCronIdleLimitVar: '$kCronIdleLimitSeconds'};

/// Keeps a long scheduled answer from being killed for looking idle.
///
/// Hermes's scheduler stops a run that has gone quiet for 10 minutes and records
/// it as `TimeoutError: Cron job '...' idle for Ns (limit 600s)`. On the path
/// this app puts people on — one prompt, one long answer, on whatever model the
/// grid routes to — that limit is reached by the answer itself rather than by
/// anything being wrong, and the user sees a failed task with nothing in it.
class HermesCronWatchdog {
  const HermesCronWatchdog(this._gateway, {AppLog log = const NoopAppLog()})
    : _log = log;

  final HermesGatewayService _gateway;
  final AppLog _log;

  /// Raise the idle limit if the file doesn't already carry one, and reload the
  /// gateway so it takes effect today rather than after the next reboot.
  ///
  /// Best-effort and never throws: it runs on the way to something the user
  /// actually asked for (pointing the assistant at a grid), and a scheduler that
  /// keeps its old limit is no worse off than before. The reason is logged (§6).
  Future<void> ensureLimit() async {
    try {
      final update = cronIdleLimitUpdate(await _gateway.readEnv());
      if (update == null) return;
      await _gateway.writeEnv(update, addedBy: 'scheduled tasks');
      _log.info(
        'tasks',
        'set $kCronIdleLimitVar=$kCronIdleLimitSeconds so a long scheduled '
            "answer isn't stopped for looking idle",
      );
      // The gateway reads .env once, at startup, and the scheduler runs inside
      // it — a running one would keep the old limit all day. Restarting a
      // gateway that isn't up would start one nobody asked for, so that case
      // waits for its own next start.
      if (!await _gateway.running()) return;
      await _gateway.restartGateway();
    } on Object catch (error) {
      _log.warn('tasks', "couldn't raise the scheduler idle limit: $error");
    }
  }
}
