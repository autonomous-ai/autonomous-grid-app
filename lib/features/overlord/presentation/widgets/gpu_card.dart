import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../data/models/gpu_metrics.dart';
import '../overlord_tokens.dart';
import 'gpu_metric_column.dart';
import 'gpu_process_list.dart';
import 'ip_chip.dart';

/// A single GPU in the fleet: title + temp/power, an optional serving endpoint,
/// the utilisation and memory columns side by side, and a footer of tags or
/// resident processes. Stateless — it renders whatever [gpu] frame it's given.
class GpuCard extends StatelessWidget {
  const GpuCard({super.key, required this.gpu});

  final GpuMetrics gpu;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      blurred: false,
      borderRadius: BorderRadius.circular(10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleRow(gpu: gpu),
          if (gpu.serving != null) ...[
            const SizedBox(height: 10),
            _ServingLine(serving: gpu.serving!),
          ],
          const SizedBox(height: 16),
          _Metrics(gpu: gpu),
          if (gpu.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Tags(tags: gpu.tags),
          ],
          if (gpu.host != null || gpu.statusNote != null) ...[
            const SizedBox(height: 10),
            _HostRow(host: gpu.host, statusNote: gpu.statusNote),
          ],
          if (gpu.processes.isNotEmpty) ...[
            const SizedBox(height: 12),
            GpuProcessList(processes: gpu.processes),
          ],
        ],
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.gpu});
  final GpuMetrics gpu;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: [
                TextSpan(text: gpu.name, style: OverlordTokens.cardTitle),
                TextSpan(
                  text: '  ·  ${gpu.model}',
                  style: OverlordTokens.cardTitle.copyWith(
                    fontWeight: FontWeight.w400,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('${gpu.tempC}°C · ${gpu.powerW}W', style: OverlordTokens.meta),
      ],
    );
  }
}

class _ServingLine extends StatelessWidget {
  const _ServingLine({required this.serving});
  final ServingInfo serving;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('serving', style: OverlordTokens.meta),
        const SizedBox(width: 8),
        Flexible(child: IpChip(endpoint: serving.endpoint)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '· ${serving.label}',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: OverlordTokens.meta,
          ),
        ),
      ],
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.gpu});
  final GpuMetrics gpu;

  @override
  Widget build(BuildContext context) {
    final mem = gpu.memory;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GpuMetricColumn(
            label: 'UTILISATION',
            value: '${gpu.utilisation.percent.round()}',
            unit: '%',
            percent: gpu.utilisation.percent,
            history: gpu.utilisation.history,
          ),
        ),
        const SizedBox(width: 28),
        Expanded(
          child: GpuMetricColumn(
            label: mem.label,
            value: mem.usedGb.toStringAsFixed(1),
            unit: '/${_fmtGb(mem.totalGb)} GB',
            secondary: '${mem.percent.round()}%',
            percent: mem.percent,
            history: mem.history,
          ),
        ),
      ],
    );
  }
}

class _Tags extends StatelessWidget {
  const _Tags({required this.tags});
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final tag in tags) _Tag(label: tag)],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppPalette.accentMuted.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: OverlordTokens.mono,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppPalette.accent,
        ),
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({required this.host, required this.statusNote});
  final String? host;
  final String? statusNote;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (host != null)
          Text(
            host!,
            style: OverlordTokens.meta.copyWith(color: AppPalette.textFaint),
          ),
        const Spacer(),
        if (statusNote != null) Text(statusNote!, style: OverlordTokens.meta),
      ],
    );
  }
}

/// `120.0 → "120"`, `31.5 → "31.5"`.
String _fmtGb(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
