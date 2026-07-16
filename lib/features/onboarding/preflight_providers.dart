import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/providers.dart';
import '../auth/logic/session_controller.dart';
import '../auth/logic/session_expiry_controller.dart';
import 'preflight_report.dart';
import 'preflight_service.dart';

/// Runs the preflight check once. Invalidate to re-run (the onboarding "Retry").
final preflightProvider = FutureProvider<PreflightReport>((ref) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);

  final service = ref.watch(gridCliServiceProvider);
  final report = await PreflightService(service).check();

  // First thing once `grid --version` confirms the CLI works: pull the latest
  // network state into `~/.grid` so the app opens in sync. Best-effort and off
  // the critical path — refresh the session list once it lands. If the CLI
  // reports the session is gone, flag it so the app prompts a re-login instead
  // of silently failing every later command.
  if (report.gridAvailable && service != null) {
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
