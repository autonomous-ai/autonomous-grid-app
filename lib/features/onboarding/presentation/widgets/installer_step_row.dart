import 'package:flutter/material.dart';

import '../../../../shared/widgets/step_row.dart';
import '../../logic/installer_stage.dart';

/// One step of the installer checklist — the installer's own row type dressed in
/// the shared [StepRow], so setup and the sign-in handshake say "here is where
/// you are" in one visual language.
///
/// A thin mapping on purpose: the shared widget knows nothing about installer
/// stages, and the installer keeps its types to itself.
class InstallerStepRow extends StatelessWidget {
  const InstallerStepRow({super.key, required this.row});

  final InstallerRow row;

  @override
  Widget build(BuildContext context) => StepRow(
    title: row.stage.title,
    status: switch (row.status) {
      InstallStatus.pending => StepStatus.pending,
      InstallStatus.running => StepStatus.running,
      InstallStatus.done => StepStatus.done,
      InstallStatus.failed => StepStatus.failed,
    },
    // A failure replaces the explanation with the reason: the step no longer
    // needs describing, it needs accounting for.
    detail: row.status == InstallStatus.failed
        ? (row.message ?? row.stage.detail)
        : row.stage.detail,
  );
}
