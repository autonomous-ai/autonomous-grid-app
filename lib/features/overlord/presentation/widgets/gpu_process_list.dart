import 'package:flutter/material.dart';

import '../../data/models/gpu_metrics.dart';
import '../overlord_tokens.dart';

/// The footer of a GPU card: each process pinned to the device, path on the
/// left (truncated) with its memory and pid on the right.
class GpuProcessList extends StatelessWidget {
  const GpuProcessList({super.key, required this.processes});

  final List<GpuProcess> processes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final process in processes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _ProcessLine(process: process),
          ),
      ],
    );
  }
}

class _ProcessLine extends StatelessWidget {
  const _ProcessLine({required this.process});

  final GpuProcess process;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            process.command,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OverlordTokens.processLine,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${process.memMb} MB · pid ${process.pid}',
          style: OverlordTokens.processLine,
        ),
      ],
    );
  }
}
