import 'dart:math' as math;

import 'fake_overlord_data.dart';
import 'models/gpu_metrics.dart';
import 'models/overlord_snapshot.dart';
import 'overlord_repository.dart';

/// Drives the dashboard from a seeded fleet, then nudges each reading on a timer
/// so the bars and sparklines breathe. Pure presentation stand-in — no I/O.
class FakeOverlordRepository implements OverlordRepository {
  FakeOverlordRepository({
    this.refresh = const Duration(milliseconds: 1000),
    this.historyWindow = const Duration(seconds: 47),
  });

  /// How often a fresh frame is emitted.
  final Duration refresh;

  /// Reported span of the sparklines (drives the "Ns history" label).
  final Duration historyWindow;

  final math.Random _rng = math.Random(42);

  @override
  Stream<OverlordSnapshot> watch() async* {
    var fleet = seedFleet();
    yield OverlordSnapshot(gpus: fleet, historyWindow: historyWindow);
    while (true) {
      await Future<void>.delayed(refresh);
      fleet = [for (final gpu in fleet) _advance(gpu)];
      yield OverlordSnapshot(gpus: fleet, historyWindow: historyWindow);
    }
  }

  /// Nudge one GPU's live values and roll its history forward by a sample.
  GpuMetrics _advance(GpuMetrics gpu) {
    final util = _nextUtil(gpu.utilisation.percent);
    final memGb = _nextMem(gpu.memory.usedGb, gpu.memory.totalGb);
    final memPct = gpu.memory.totalGb <= 0
        ? 0.0
        : (memGb / gpu.memory.totalGb) * 100;

    return GpuMetrics(
      id: gpu.id,
      name: gpu.name,
      model: gpu.model,
      tempC: (gpu.tempC + _jitterInt(1)).clamp(20, 95),
      powerW: (gpu.powerW + _jitterInt(2)).clamp(5, 700),
      utilisation: UtilisationMetric(
        percent: util,
        history: _roll(gpu.utilisation.history, util),
      ),
      memory: MemoryMetric(
        label: gpu.memory.label,
        usedGb: memGb,
        totalGb: gpu.memory.totalGb,
        history: _roll(gpu.memory.history, memPct),
      ),
      serving: gpu.serving,
      host: gpu.host,
      tags: gpu.tags,
      statusNote: gpu.statusNote,
      processes: gpu.processes,
    );
  }

  /// Mostly idle with the occasional brief spike — what an unloaded fleet looks
  /// like between requests.
  double _nextUtil(double current) {
    if (_rng.nextDouble() < 0.12) return (10 + _rng.nextInt(60)).toDouble();
    return (current * 0.5 + _rng.nextDouble() * 3).clamp(0, 100).toDouble();
  }

  /// Memory drifts only slightly — models stay resident once loaded.
  double _nextMem(double usedGb, double totalGb) {
    final drift = (_rng.nextDouble() - 0.5) * 0.4;
    return (usedGb + drift).clamp(0, totalGb).toDouble();
  }

  int _jitterInt(int spread) => _rng.nextInt(spread * 2 + 1) - spread;

  List<double> _roll(List<double> history, double next) =>
      [...history.skip(1), next];
}
