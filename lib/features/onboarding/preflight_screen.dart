import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preflight_providers.dart';
import 'preflight_report.dart';

/// Shown when `grid` cannot be found. Explains the gap and offers a re-check.
class PreflightScreen extends ConsumerWidget {
  const PreflightScreen({super.key, required this.report});

  final PreflightReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('Grid needs setup', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                "Grid couldn't find the components it needs to run. Please "
                'install them, then check again.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              _CheckRow(label: 'Grid core', ok: report.gridAvailable),
              _CheckRow(
                label: 'Docker or Podman (needed to create your own grid)',
                ok: report.hasContainerEngine,
                optional: true,
                detail: report.containerEngine,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => ref.invalidate(preflightProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Check again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.label,
    required this.ok,
    this.optional = false,
    this.detail,
  });

  final String label;
  final bool ok;
  final bool optional;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final color = ok
        ? Colors.green
        : optional
            ? Colors.orange
            : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(detail != null ? '$label — $detail' : label)),
        ],
      ),
    );
  }
}
