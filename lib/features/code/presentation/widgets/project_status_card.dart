import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/detail_widgets.dart';
import '../../logic/code_tasks_controller.dart';
import '../../logic/project_status.dart';
import 'code_notice.dart';

/// Where the project stands: what the team shares, what this member has that
/// the team does not, and what is holding their one task slot.
class ProjectStatusCard extends StatelessWidget {
  const ProjectStatusCard({super.key, required this.status});

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSection(
          title: 'Where it is',
          children: [
            MetaRow(
              label: 'The team’s copy',
              value: status.mainCommit == null
                  ? 'Nothing imported yet'
                  : shortCommit(status.mainCommit!),
            ),
            MetaRow(
              label: 'Your copy',
              value: status.wipCommit == null
                  ? 'Nothing of yours yet'
                  : shortCommit(status.wipCommit!),
            ),
            MetaRow(label: 'Distance', value: _distance(status)),
          ],
        ),
        if (status.slotHolder case final holder?) ...[
          const SizedBox(height: 16),
          _SlotHolderRow(holder: holder),
        ],
        if (fleetNotice(status) case final notice?) ...[
          const SizedBox(height: 16),
          CodeNotice(message: notice),
        ],
      ],
    );
  }
}

/// A commit as a person reads it. Full oids are forty characters of noise in a
/// row whose job is "did this move".
String shortCommit(String commit) =>
    commit.length <= 8 ? commit : commit.substring(0, 8);

/// How far this member's work is from the team's, in a sentence.
///
/// Absent counts are said as "nothing to compare", never as `0 / 0` — that
/// reads as up to date, and the next thing somebody does on that belief is
/// publish a branch that does not exist.
String _distance(ProjectStatus status) {
  final ahead = status.ahead;
  final behind = status.behind;
  if (ahead == null || behind == null) {
    return 'Nothing to compare yet — run a task first';
  }
  if (ahead == 0 && behind == 0) return 'The same as the team’s copy';
  final parts = [
    if (ahead > 0) '$ahead of yours not shared yet',
    if (behind > 0) '$behind from the team you don’t have',
  ];
  return parts.join(' · ');
}

/// The task holding this member's slot, and the way into it. Without the id
/// there is nothing to wait on, read or stop.
class _SlotHolderRow extends ConsumerWidget {
  const _SlotHolderRow({required this.holder});

  final SlotHolder holder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CodeNotice(
    icon: Icons.hourglass_empty_rounded,
    message:
        'Your task slot is taken by a task that is '
        '${holder.state.label.toLowerCase()}. One at a time in a project.',
    trailing: TextButton(
      onPressed: () =>
          ref.read(selectedCodeTaskProvider.notifier).select(holder.id),
      child: const Text('Open it'),
    ),
  );
}
