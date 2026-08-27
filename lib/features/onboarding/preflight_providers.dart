import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/cli/grid_resolution.dart';
import '../../infrastructure/logging/app_log.dart';
import '../../infrastructure/providers.dart';
import '../auth/logic/session_controller.dart';
import '../auth/logic/session_expiry_controller.dart';
import 'preflight_report.dart';
import 'preflight_service.dart';

/// Runs the preflight check once. Invalidate to re-run (the onboarding "Retry").
final preflightProvider = FutureProvider<PreflightReport>((ref) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);

  final resolution = ref.watch(gridResolutionProvider);
  final service = ref.watch(gridCliServiceProvider);
  final report = await PreflightService(service, resolution).check();
  _log(ref.read(appLogProvider), report, resolution);

  // First thing once `grid --version` confirms the CLI works: pull the latest
  // network state into `~/.grid` so the app opens in sync. Best-effort and off
  // the critical path — refresh the session list once it lands. If the CLI
  // reports the session is gone, flag it so the app prompts a re-login instead
  // of silently failing every later command.
  if (report.canProceed && service != null) {
    unawaited(
      service.run(['sync']).then((result) {
        if (disposed) return;
        if (result.sessionExpired) {
          unawaited(ref.read(sessionExpiryProvider.notifier).onExpired());
          return;
        }
        ref.invalidate(sessionProvider);
      }),
    );
  }
  return report;
});

/// Leaves the check in `~/.grid/logs/app.log`. A blocked preflight is the one
/// state the user can't get past — and until now it wrote nothing at all, so
/// "it says Grid needs setup" arrived with no way to tell a missing helper from
/// one we shipped for the wrong CPU. The probed paths are the evidence.
void _log(AppLog log, PreflightReport report, GridResolution resolution) {
  final issue = report.issue;
  if (issue == null) {
    log.info(
      'app',
      'preflight ok: ${report.gridVersion ?? 'grid (no version printed)'} '
          'at ${resolution.path}',
    );
    return;
  }
  final probed = resolution.probed.map((line) => '\n    $line').join();
  log.warn('app', 'preflight blocked: ${issue.summary}. Probed:$probed');
}
