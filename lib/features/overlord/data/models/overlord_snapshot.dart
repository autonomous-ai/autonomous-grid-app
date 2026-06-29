import 'package:flutter/foundation.dart';

import 'gpu_metrics.dart';

/// One frame of the whole dashboard. Today it carries the GPU fleet and the
/// length of the rolling history window; Storage & System and the Orchestrator
/// will hang off this same snapshot as those panels come online.
@immutable
class OverlordSnapshot {
  const OverlordSnapshot({
    required this.gpus,
    required this.historyWindow,
  });

  final List<GpuMetrics> gpus;

  /// How far back the sparklines reach — rendered as `"${inSeconds}s history"`.
  final Duration historyWindow;
}
