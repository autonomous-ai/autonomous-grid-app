import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/task_steps_store.dart';
import 'task_feed_view.dart';

/// What a finished task did, folded away under its answer.
///
/// Closed by default and open on a click: the answer is what a finished task is
/// read for, and the hundreds of tool calls behind it are what you go looking
/// for when the answer doesn't explain itself. Before this, they were simply
/// gone the moment the task landed (issue #30).
///
/// Silent when nothing was kept — every task that ran before the record
/// existed, and any whose run was never watched by this machine. A disclosure
/// that opens onto "nothing here" is worse than no disclosure.
class TaskStepsDisclosure extends ConsumerStatefulWidget {
  const TaskStepsDisclosure({super.key, required this.taskId});

  final String taskId;

  @override
  ConsumerState<TaskStepsDisclosure> createState() =>
      _TaskStepsDisclosureState();
}

class _TaskStepsDisclosureState extends ConsumerState<TaskStepsDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Absent until the file has been read: a row that appears and then vanishes
    // is worse than one that arrives a frame late.
    final run = ref
        .watch(taskStepsProvider(widget.taskId))
        .whenOrNull(data: (run) => run);
    if (run == null || run.isEmpty) return const SizedBox.shrink();

    final count = run.lines.length + run.dropped;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        _Toggle(
          open: _open,
          label: _open
              ? 'Hide what it did'
              : 'Show what it did · $count ${count == 1 ? 'step' : 'steps'}',
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          // All of it, not a tail: this is the record somebody opened on
          // purpose.
          TaskLinesView(lines: run.lines, dropped: run.dropped),
        ],
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.open, required this.label, required this.onTap});

  final bool open;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              open
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_right_rounded,
              size: 16,
              color: AppPalette.textFaint,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
