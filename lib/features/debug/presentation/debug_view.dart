import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/section_scaffold.dart';

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
          _Toolbar(count: logs.length),
          const SizedBox(height: 12),
          Expanded(
            child: logs.isEmpty
                ? const ComingSoon(
                    message:
                        'No grid commands yet — interact with the app and '
                        'they’ll show up here.')
                : ListView.separated(
                    itemCount: logs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
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
        Text('$count command${count == 1 ? '' : 's'}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const Spacer(),
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

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log});
  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.divider),
      ),
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
                      fontFamily: 'monospace', color: AppPalette.textPrimary),
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
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
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
          child: CircularProgressIndicator(strokeWidth: 2)),
      CliCallStatus.success =>
        const Icon(Icons.check_circle, size: 16, color: AppPalette.online),
      CliCallStatus.failed => Icon(Icons.error,
          size: 16, color: Theme.of(context).colorScheme.error),
    };
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.log});
  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
        color: AppPalette.textFaint, fontFamily: 'monospace', fontSize: 11.5);
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
    final dur =
        log.duration == null ? '' : ' · ${_formatDuration(log.duration!)}';
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
