import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/task_serving_store.dart';
import '../../../shared/theme/app_theme.dart';

/// Whether this computer also takes the grid's **coding tasks**, not just chat.
///
/// A different bargain from sharing a model, and the panel says so: a task
/// clones a teammate's repository here, runs Claude Code against it with
/// permission to change files, and spends this computer's own Claude
/// subscription doing it. So it is off until somebody says otherwise.
class TaskServingPanel extends ConsumerWidget {
  const TaskServingPanel({super.key});

  /// The most this app offers to run at once.
  ///
  /// Not a limit the grid imposes — it is the number the *team* shares, so a
  /// machine set to four is four tasks running against four checkouts and four
  /// concurrent agents on one subscription. Past a handful the honest answer is
  /// another computer, not a bigger number here.
  static const _maxConcurrent = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final prefs = ref.watch(taskServingProvider);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Also take coding tasks',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Teammates can hand this computer a coding job. It copies '
                    'their project here, lets Claude Code change files in that '
                    'copy, and sends the result back, spending this '
                    'computer’s own Claude allowance.',
                    style: quiet,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: prefs.enabled,
              onChanged: (value) =>
                  ref.read(taskServingProvider.notifier).setEnabled(value),
            ),
          ],
        ),
        if (prefs.enabled) ...[
          const SizedBox(height: 12),
          _Concurrency(
            value: prefs.maxTasks,
            max: _maxConcurrent,
            onChanged: (value) =>
                ref.read(taskServingProvider.notifier).setMaxTasks(value),
          ),
          const SizedBox(height: 10),
          Text(
            // Said plainly because the switch is instant and this is not: the
            // loop that claims tasks lives inside the join, so flipping it
            // while an engine is already running changes nothing until the
            // engine is started again.
            'Takes effect the next time you start sharing. If this computer is '
            'sharing right now, stop and start it again.',
            style: quiet,
          ),
          if (Platform.isLinux) ...[
            const SizedBox(height: 8),
            Text(
              'On Linux this needs bubblewrap and socat installed, so a task '
              'runs boxed in. Without them the grid refuses the task rather '
              'than running it unconfined.',
              style: quiet,
            ),
          ],
        ],
      ],
    );
  }
}

/// How many tasks run here at once.
class _Concurrency extends StatelessWidget {
  const _Concurrency({
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            'At a time',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        DropdownButton<int>(
          value: value > max ? max : value,
          underline: const SizedBox.shrink(),
          items: [
            for (var count = 1; count <= max; count++)
              DropdownMenuItem(value: count, child: Text('$count')),
          ],
          onChanged: (picked) => picked == null ? null : onChanged(picked),
        ),
      ],
    );
  }
}
