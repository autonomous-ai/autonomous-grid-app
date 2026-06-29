import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import 'widgets/gpu_panel.dart';
import 'widgets/orchestrator_panel.dart';
import 'widgets/overlord_chrome.dart';
import 'widgets/storage_panel.dart';

/// The Overlord dashboard: its own chrome over three columns — GPUs (live),
/// Storage & System, and the Orchestrator. Rendered inside the app shell's
/// content area as the "Overlord" section.
class OverlordView extends StatelessWidget {
  const OverlordView({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppPalette.windowBg,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          OverlordChrome(),
          SizedBox(height: 16),
          Expanded(child: _Columns()),
        ],
      ),
    );
  }
}

class _Columns extends StatelessWidget {
  const _Columns();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        Expanded(flex: 10, child: GpuPanel()),
        SizedBox(width: 16),
        Expanded(flex: 10, child: StoragePanel()),
        SizedBox(width: 16),
        Expanded(flex: 11, child: OrchestratorPanel()),
      ],
    );
  }
}
