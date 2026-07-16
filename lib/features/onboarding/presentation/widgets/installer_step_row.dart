import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../logic/installer_stage.dart';

/// One step of the installer checklist.
///
/// The running step is lifted onto a card and given its explanation; the ones
/// still to come are dimmed to a single line. That way the user's eye lands on
/// the one thing happening now, and the list still shows what the whole job is.
class InstallerStepRow extends StatelessWidget {
  const InstallerStepRow({super.key, required this.row});

  final InstallerRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = row.status == InstallStatus.running;
    final isFailed = row.status == InstallStatus.failed;
    final isPending = row.status == InstallStatus.pending;

    final title = Text(
      row.stage.title,
      style: theme.textTheme.bodyLarge?.copyWith(
        fontWeight: isRunning ? FontWeight.w600 : FontWeight.w400,
        color: isPending
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
            : theme.colorScheme.onSurface,
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isRunning ? theme.colorScheme.surfaceContainerHighest : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Center(child: _StatusIcon(status: row.status)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                // The explanation is only worth the space on the step running
                // now, or on the one that broke.
                if (isRunning || isFailed) ...[
                  const SizedBox(height: 2),
                  Text(
                    isFailed
                        ? (row.message ?? row.stage.detail)
                        : row.stage.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isFailed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final InstallStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (status) {
      InstallStatus.pending => Icon(
        Icons.circle,
        size: 8,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
      ),
      InstallStatus.running => const AppSpinner(),
      InstallStatus.done => Icon(
        Icons.check_circle,
        size: 18,
        color: AppPalette.online,
      ),
      InstallStatus.failed => Icon(
        Icons.error,
        size: 18,
        color: theme.colorScheme.error,
      ),
    };
  }
}
