import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/app_theme.dart';
import '../../core/app_environment.dart';
import '../../shared/widgets/error_box.dart';
import '../network/presentation/detail_widgets.dart';
import 'preflight_providers.dart';
import 'preflight_report.dart';

/// Where users go to install or get help with the `grid` background helper —
/// prod in release, the staging site in dev (see [AppEnvironment.websiteUrl]).
String get _helpUrl => AppEnvironment.websiteUrl;
String get _installCommand =>
    'curl -fsSL ${AppEnvironment.websiteUrl}/install.sh | bash';

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
              Icon(
                Icons.warning_amber_rounded,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text('Grid needs setup', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                report.gridError != null
                    ? "Grid is installed but couldn't start. Fix the issue "
                          'below, then check again.'
                    : "Grid needs its background helper installed before it can "
                          'run. Install it using the steps below, then check again.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              _CheckRow(
                label: 'Grid background helper',
                ok: report.gridAvailable,
              ),
              if (report.gridError != null) ...[
                const SizedBox(height: 16),
                ErrorBox(message: report.gridError!),
              ],
              // Only the "missing" case needs install instructions; a present-
              // but-broken install is a different problem (shown via ErrorBox).
              if (report.gridError == null) ...[
                const SizedBox(height: 20),
                Text('Install it', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(
                  'On macOS or Linux, run this in a terminal:',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _InstallCommand(command: _installCommand),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () => ref.invalidate(preflightProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check again'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(_helpUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: const Text('Get help'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A copyable one-liner install command, shown in monospace with a copy button.
class _InstallCommand extends StatelessWidget {
  const _InstallCommand({required this.command});
  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              maxLines: 1,
              style: TextStyle(
                fontFamily: AppFont.mono,
                fontFamilyFallback: AppFont.monoFallback,
                fontSize: 12.5,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            onPressed: () => copyToClipboard(context, command),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppPalette.online : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}
