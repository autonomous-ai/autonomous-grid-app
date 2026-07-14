import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../infrastructure/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../onboarding/preflight_providers.dart';
import '../../onboarding/preflight_report.dart';

/// Debug tab — a live log of every `grid` command the app runs (newest first).
/// Fed by [LoggingGridCliService]; handy for seeing exactly what the UI shells
/// out to and whether it succeeded.
class DebugView extends ConsumerWidget {
  const DebugView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(commandLogProvider);
    return SectionScaffold(
      title: 'Debug',
      subtitle: 'Every grid command this app runs',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WhichGridCard(),
          const SizedBox(height: 12),
          _Toolbar(count: logs.length),
          const SizedBox(height: 12),
          Expanded(
            child: logs.isEmpty
                ? const ComingSoon(
                    message:
                        'No grid commands yet — interact with the app and '
                        'they’ll show up here.',
                  )
                : ListView.separated(
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _LogTile(log: logs[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.count});
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          '$count command${count == 1 ? '' : 's'}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        const _OpenLogsButton(),
        const SizedBox(width: 4),
        TextButton.icon(
          onPressed: count == 0
              ? null
              : () => ref.read(commandLogProvider.notifier).clear(),
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Clear'),
        ),
      ],
    );
  }
}

/// Opens `~/.grid/logs` in the file manager.
///
/// The list above is only this session's commands, held in memory — the files on
/// disk are what survive a crash and what a user can actually attach to a bug
/// report. Without this they'd have to be told a hidden path to type into Finder.
class _OpenLogsButton extends ConsumerWidget {
  const _OpenLogsButton();

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final directory = GridPaths.logsDir;
    final messenger = ScaffoldMessenger.of(context);
    // Nothing has been logged yet on a fresh install — the folder simply isn't
    // there, and "couldn't open it" would be the wrong story.
    if (!directory.existsSync()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No logs yet — nothing has run.')),
      );
      return;
    }
    final opened = await ref
        .read(hostShellServiceProvider)
        .openFolder(directory.path);
    if (opened) return;
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't open ${directory.path}")),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      onPressed: () => _open(context, ref),
      icon: const Icon(Icons.folder_open_rounded, size: 16),
      label: const Text('Open logs'),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log});
  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusIcon(status: log.status),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  log.command,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _Meta(log: log),
            ],
          ),
          if (log.error != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: SelectableText(
                log.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final CliCallStatus status;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      CliCallStatus.running => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      CliCallStatus.success => Icon(
        Icons.check_circle,
        size: 16,
        color: AppPalette.online,
      ),
      CliCallStatus.failed => Icon(
        Icons.error,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      ),
    };
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.log});
  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: AppPalette.textFaint,
      fontFamily: 'monospace',
      fontSize: 11.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(log.kind.name, style: style),
        const SizedBox(height: 2),
        Text(_detail(log), style: style),
      ],
    );
  }

  String _detail(GridCommandLog log) {
    final time = _formatTime(log.startedAt);
    if (log.status == CliCallStatus.running) return '$time · running…';
    final dur = log.duration == null
        ? ''
        : ' · ${_formatDuration(log.duration!)}';
    final code = switch (log.exitCode) {
      null => '',
      final c when log.kind == CliCallKind.http => ' · HTTP $c',
      final c => ' · exit $c',
    };
    return '$time$dur$code';
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)}s';
}

/// Shows which `grid` binary the app resolved (and from where), plus whether it
/// actually runs — the first thing to check when commands fail (e.g. a wrong
/// path or an arch mismatch). Re-check re-resolves and re-runs the preflight.
class _WhichGridCard extends ConsumerWidget {
  const _WhichGridCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final path = ref.watch(gridPathProvider);
    final preflight = ref.watch(preflightProvider);
    final gridBin = Platform.environment['GRID_BIN'];

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 16, color: AppPalette.textFaint),
              const SizedBox(width: 8),
              Text('grid binary', style: theme.textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: 'Re-check',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: () {
                  ref.invalidate(gridPathProvider);
                  ref.invalidate(preflightProvider);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          _PathRow(
            label: 'path',
            value: path ?? 'Not found on this system',
            ok: path != null,
          ),
          if (gridBin != null && gridBin.isNotEmpty)
            _PathRow(label: 'GRID_BIN', value: gridBin, ok: true),
          const SizedBox(height: 6),
          _version(theme, preflight),
        ],
      ),
    );
  }

  Widget _version(ThemeData theme, AsyncValue<PreflightReport> preflight) {
    return preflight.when(
      loading: () => Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('checking…', style: theme.textTheme.bodySmall),
        ],
      ),
      error: (e, _) => SelectableText(
        'check failed: $e',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
      data: (report) {
        // Health is the exit-0 signal (`gridAvailable`), not the presence of a
        // version string — a working `grid` can exit 0 without printing one.
        if (report.gridAvailable) {
          return Row(
            children: [
              Icon(
                Icons.check_circle,
                size: 14,
                color: AppPalette.online,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  report.gridVersion ?? 'installed (version unknown)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                report.gridError ?? 'grid not found',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value, required this.ok});
  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: ok ? AppPalette.textPrimary : theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
