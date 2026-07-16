import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../data/models/overlord_snapshot.dart';
import '../../logic/overlord_providers.dart';
import '../overlord_tokens.dart';
import 'gpu_card.dart';
import 'panel_frame.dart';
import 'panel_message.dart';

/// Left column: the live GPU fleet, one [GpuCard] per device, with the rolling
/// history window shown in the header.
class GpuPanel extends ConsumerWidget {
  const GpuPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(overlordSnapshotProvider);
    return PanelFrame(
      label: 'GPUs',
      trailing: _HistoryLabel(window: snapshot.asData?.value.historyWindow),
      child: snapshot.when(
        loading: () => const PanelMessage(
          icon: Icons.memory_outlined,
          text: 'Connecting to fleet…',
        ),
        error: (err, _) =>
            PanelMessage(icon: Icons.error_outline, text: '$err'),
        data: (data) => _GpuList(snapshot: data),
      ),
    );
  }
}

class _GpuList extends StatelessWidget {
  const _GpuList({required this.snapshot});
  final OverlordSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot.gpus.isEmpty) {
      return const PanelMessage(
        icon: Icons.memory_outlined,
        text: 'No GPUs reporting.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: snapshot.gpus.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => GpuCard(gpu: snapshot.gpus[i]),
    );
  }
}

class _HistoryLabel extends StatelessWidget {
  const _HistoryLabel({required this.window});
  final Duration? window;

  @override
  Widget build(BuildContext context) {
    if (window == null) return const SizedBox.shrink();
    return Text(
      '${window!.inSeconds}s history',
      style: TextStyle(
        fontFamily: OverlordTokens.mono,
        fontSize: 11,
        color: AppPalette.textFaint,
      ),
    );
  }
}
