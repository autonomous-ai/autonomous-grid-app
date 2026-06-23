import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/providers.dart';
import 'preflight_report.dart';
import 'preflight_service.dart';

/// Runs the preflight check once. Invalidate to re-run (the onboarding "Retry").
final preflightProvider = FutureProvider<PreflightReport>((ref) {
  final service = ref.watch(gridCliServiceProvider);
  return PreflightService(service).check();
});
