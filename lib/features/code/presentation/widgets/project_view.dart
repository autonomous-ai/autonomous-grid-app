import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/section_scaffold.dart';
import '../../logic/code_project.dart';
import '../../logic/code_projects_controller.dart';
import '../../logic/project_status.dart';
import '../../logic/project_status_controller.dart';
import 'code_failure.dart';
import 'code_notice.dart';
import 'import_repo_dialog.dart';
import 'project_actions_bar.dart';
import 'task_composer.dart';
import 'task_transcript.dart';

/// The open project: everything the team has run against it, as a conversation,
/// with the box to ask for the next thing at its foot.
///
/// It is laid out as the chat half is — history above, composer below — because
/// it is the same act: you say what you want, and a computer does it. The
/// difference is only *whose* computer, and that belongs in the turn rather than
/// in the shape of the screen.
class ProjectView extends ConsumerWidget {
  const ProjectView({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref
        .watch(codeProjectsProvider)
        .asData
        ?.value
        .where((candidate) => candidate.id == projectId)
        .firstOrNull;
    final status = ref.watch(projectStatusProvider(projectId));

    return SectionScaffold(
      title: project?.name ?? 'Project',
      subtitle:
          'Ask for a change. A computer on the grid runs it and pushes the '
          'result to your own branch — nobody works on top of anybody else.',
      child: switch (status) {
        AsyncData(:final value) when value.needsImport => _NeedsImport(
          projectId: projectId,
        ),
        AsyncData(:final value) => _Conversation(
          status: value,
          project: project,
        ),
        AsyncError(:final error) => CodeFailure(
          message: '$error',
          onRetry: () => ref.invalidate(projectStatusProvider(projectId)),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

/// The project exists but has no code in it. Nothing else here can work until
/// somebody imports a repository, so nothing else is offered.
class _NeedsImport extends StatelessWidget {
  const _NeedsImport({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.folderGit2300,
    title: 'No code in this project yet',
    message:
        'Bring in an existing repository, with its history. That is the only '
        'way a project gets its code, and no task can run until it has some.',
    action: FilledButton(
      onPressed: () => showImportRepoDialog(context, projectId: projectId),
      child: const Text('Bring in a repository'),
    ),
  );
}

/// The working screen: what can be done to the project, what has been run
/// against it, and the box for the next thing.
class _Conversation extends StatelessWidget {
  const _Conversation({required this.status, required this.project});

  final ProjectStatus status;
  final GridProject? project;

  @override
  Widget build(BuildContext context) {
    final holder = status.slotHolder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProjectActionsBar(
          status: status,
          projectName: project?.name,
          // Admitting people is the owner's call, so the button only appears
          // where pressing it would work.
          canInvite: project?.isOwner ?? false,
        ),
        const SizedBox(height: 8),
        _Distance(status: status),
        const SizedBox(height: 14),
        Expanded(child: TaskTranscript(projectId: status.projectId)),
        // Everything that says why the next thing may not go as expected sits
        // directly above the box that starts it, in the order it would bite:
        // your own slot first, then the grid having nobody to run it.
        if (holder != null) ...[
          const SizedBox(height: 10),
          CodeNotice(
            icon: Icons.hourglass_empty_rounded,
            message:
                'Your last task is still '
                '${holder.state.label.toLowerCase()} — a project runs one of '
                'yours at a time. Stop it above to start another.',
          ),
        ],
        if (fleetNotice(status) case final notice?) ...[
          const SizedBox(height: 10),
          CodeNotice(message: notice),
        ],
        const SizedBox(height: 12),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kTaskColumnWidth),
            child: TaskComposer(
              // Keyed by the project so the box belongs to the one on screen.
              // Without it the same state is reused across a switch, and a
              // half-written request would be sitting in another project's
              // composer with Send under it.
              key: ValueKey(status.projectId),
              projectId: status.projectId,
              slotHeld: holder != null,
            ),
          ),
        ),
      ],
    );
  }
}

/// How far this member's work is from the team's, in one quiet line.
class _Distance extends StatelessWidget {
  const _Distance({required this.status});

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      distanceSummary(status),
      style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
    );
  }
}
