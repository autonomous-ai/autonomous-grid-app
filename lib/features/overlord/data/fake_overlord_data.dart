import 'dart:math' as math;

import 'models/gpu_metrics.dart';

/// Number of history samples held per metric (≈ the "47s history" window).
const int kHistorySamples = 48;

/// A gentle, deterministic seed series around [base] so sparklines look alive
/// on first paint without any randomness at construction time.
List<double> seedSeries(double base, {double amp = 2}) => List<double>.generate(
  kHistorySamples,
  (i) => (base + amp * math.sin(i / 3)).clamp(0, 100).toDouble(),
);

/// The initial fleet, mirroring the reference dashboard. This is the only place
/// that hardcodes the mock topology; swap [FakeOverlordRepository] for a real
/// client and this file goes away.
List<GpuMetrics> seedFleet() => [
  GpuMetrics(
    id: 'dgx-spark',
    name: 'DGX Spark',
    model: 'NVIDIA GB10',
    tempC: 52,
    powerW: 12,
    utilisation: UtilisationMetric(percent: 0, history: seedSeries(1, amp: 3)),
    memory: MemoryMetric(
      label: 'UNIFIED MEM',
      usedGb: 84.7,
      totalGb: 120,
      history: seedSeries(71, amp: 1.5),
    ),
    host: '192.168.50.251',
    tags: const ['spark-latest'],
    statusNote: 'vLLM: Up 7 days',
  ),
  GpuMetrics(
    id: 'gpu-0',
    name: 'GPU 0',
    model: 'NVIDIA RTX PRO 6000 Blackwell Max-Q',
    tempC: 45,
    powerW: 12,
    utilisation: UtilisationMetric(percent: 0, history: seedSeries(1, amp: 3)),
    memory: MemoryMetric(
      label: 'VRAM',
      usedGb: 92.1,
      totalGb: 96,
      history: seedSeries(96, amp: 0.6),
    ),
    serving: const ServingInfo(
      endpoint: '192.168.50.134:8000',
      label: 'overlord-testing',
    ),
    processes: const [
      GpuProcess(command: '/usr/bin/sunshine', memMb: 552, pid: 7399),
      GpuProcess(
        command: '/media/samcardillo/Dev/llama.cpp-glm/build/bin/llama-server',
        memMb: 92540,
        pid: 750284,
      ),
    ],
  ),
  GpuMetrics(
    id: 'gpu-1',
    name: 'GPU 1',
    model: 'NVIDIA GeForce RTX 5090',
    tempC: 35,
    powerW: 13,
    utilisation: UtilisationMetric(percent: 0, history: seedSeries(1, amp: 3)),
    memory: MemoryMetric(
      label: 'VRAM',
      usedGb: 28.4,
      totalGb: 32,
      history: seedSeries(89, amp: 0.8),
    ),
    processes: const [
      GpuProcess(
        command: '/mnt/bellum/swarmui/dlbackend/ComfyUI/venv/bin/python',
        memMb: 27792,
        pid: 1190474,
      ),
    ],
  ),
  GpuMetrics(
    id: 'gpu-2',
    name: 'GPU 2',
    model: 'NVIDIA RTX PRO 6000 Blackwell Workstation',
    tempC: 34,
    powerW: 9,
    utilisation: UtilisationMetric(percent: 0, history: seedSeries(1, amp: 3)),
    memory: MemoryMetric(
      label: 'VRAM',
      usedGb: 89.6,
      totalGb: 96,
      history: seedSeries(93, amp: 0.7),
    ),
    serving: const ServingInfo(
      endpoint: '192.168.50.134:8080',
      label: 'overlord-latest',
    ),
    processes: const [
      GpuProcess(
        command: '/media/samcardillo/Dev/llama.cpp-glm/build/bin/llama-server',
        memMb: 90534,
        pid: 750284,
      ),
    ],
  ),
];
