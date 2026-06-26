import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/providers.dart';
import '../auth/logic/session_controller.dart';
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
  // the critical path — refresh the session list once it lands.
  if (report.gridAvailable && service != null) {
    unawaited(service.run(['sync']).then((_) {
      if (!disposed) ref.invalidate(sessionProvider);
    }));
  }
  return report;
});
