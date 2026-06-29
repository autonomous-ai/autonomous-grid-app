import 'package:flutter/foundation.dart';

/// A rolling utilisation reading (0–100%) plus its recent history, used to draw
/// the big number and the sparkline under it.
@immutable
class UtilisationMetric {
  const UtilisationMetric({required this.percent, required this.history});

  /// Current GPU utilisation, 0–100.
  final double percent;

  /// Recent samples (oldest → newest), each 0–100, for the sparkline.
  final List<double> history;
}

/// A memory reading — used/total in GB — shown as `used /total GB` with a
/// percent-full bar. Labelled per GPU ("UNIFIED MEM" on the GB10, "VRAM" else).
@immutable
class MemoryMetric {
  const MemoryMetric({
    required this.label,
    required this.usedGb,
    required this.totalGb,
    required this.history,
  });

  final String label;
  final double usedGb;
  final double totalGb;

  /// Recent percent-full samples (oldest → newest), each 0–100.
  final List<double> history;

  double get percent => totalGb <= 0 ? 0 : (usedGb / totalGb) * 100;
}

/// The endpoint this GPU is serving on, plus the human label of what it runs.
/// Shown as a copyable IP chip: `serving [192.168.50.134:8000] · overlord-testing`.
@immutable
class ServingInfo {
  const ServingInfo({required this.endpoint, required this.label});

  final String endpoint;
  final String label;
}

/// One process pinned to a GPU, shown in the card footer:
/// `/usr/bin/sunshine    552 MB · pid 7399`.
@immutable
class GpuProcess {
  const GpuProcess({
    required this.command,
    required this.memMb,
    required this.pid,
  });

  final String command;
  final int memMb;
  final int pid;
}

/// A single GPU's live telemetry — everything one card needs to render.
@immutable
class GpuMetrics {
  const GpuMetrics({
    required this.id,
    required this.name,
    required this.model,
    required this.tempC,
    required this.powerW,
    required this.utilisation,
    required this.memory,
    this.serving,
    this.host,
    this.tags = const [],
    this.statusNote,
    this.processes = const [],
  });

  /// Stable key for list diffing (e.g. `gpu-0`, `dgx-spark`).
  final String id;

  /// Short name shown bold: `DGX Spark`, `GPU 0`.
  final String name;

  /// Vendor/model line: `NVIDIA RTX PRO 6000 Blackwell Max-Q`.
  final String model;

  final int tempC;
  final int powerW;

  final UtilisationMetric utilisation;
  final MemoryMetric memory;

  /// Set when the GPU is actively serving an endpoint (chip under the title).
  final ServingInfo? serving;

  /// A bare host/IP shown plainly in the footer (e.g. the GB10's `192.168.50.251`).
  final String? host;

  /// Small pills under the title, e.g. `spark-latest`.
  final List<String> tags;

  /// Right-aligned status note by the tags, e.g. `vLLM: Up 7 days`.
  final String? statusNote;

  /// Processes occupying the GPU, shown in the footer.
  final List<GpuProcess> processes;
}
