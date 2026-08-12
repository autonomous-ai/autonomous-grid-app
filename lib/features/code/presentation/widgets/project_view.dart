import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/section_scaffold.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../playground/presentation/transcript_view.dart';
import '../../logic/code_project.dart';
import '../../logic/code_projects_controller.dart';
import '../../logic/code_side_panel.dart';
import '../../logic/project_flow.dart';
import '../../logic/project_status.dart';
import '../../logic/project_status_controller.dart';
import 'code_failure.dart';
import 'code_notice.dart';
import 'code_side_panel.dart';
import 'import_repo_dialog.dart';
import 'project_header_actions.dart';
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

    // The side panel — the clone browsed, its diff reviewed, a terminal in it —
    // only earns its place once the project has code to work on, and only when
    // the user has asked for it.
    final hasCode = switch (status) {
      AsyncData(:final value) => !value.needsImport,
      _ => false,
    };
    final panelOpen = ref.watch(codeSidePanelOpenProvider) && hasCode;

    return SectionScaffold(
      title: project?.name ?? 'Project',
      subtitle:
          'Ask for a change. A computer on the grid runs it and pushes the '
          'result to your own branch — nobody works on top of anybody else.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
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
          ),
          if (panelOpen) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 460,
              child: CodeSidePanel(
                // Keyed so its Files/Review/Terminal belong to the open project
                // and a switch re-roots them at the new one's copy.
                key: ValueKey(projectId),
                projectId: projectId,
                projectName: project?.name,
              ),
            ),
          ],
        ],
      ),
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
class _Conversation extends ConsumerWidget {
  const _Conversation({required this.status, required this.project});

  final ProjectStatus status;
  final GridProject? project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holder = status.slotHolder;
    // The flow catches up and publishes on its own; the one thing the user has
    // to be told is what it did without them, so a promote that failed doesn't
    // pass in silence. Toasted here rather than in the flow, which has no
    // context of its own.
    ref.listen(projectFlowProvider(status.projectId).select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice == null || !context.mounted) return;
      ToastScope.show(
        context,
        ToastSpec(message: notice.message, severity: _severity(notice.level)),
      );
    });
    final publishing = ref.watch(
      projectFlowProvider(status.projectId).select((s) => s.isPublishing),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _Distance(status: status)),
            ProjectHeaderActions(
              status: status,
              projectName: project?.name,
              // Admitting people is the owner's call, so the invite behind
              // "Who is in it" only appears where pressing it would work.
              canInvite: project?.isOwner ?? false,
            ),
            const _PanelToggle(),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TaskTranscript(
            // Keyed by the project so its scroll and follow state belong to the
            // one on screen, and a switch lands at the new project's newest turn.
            key: ValueKey(status.projectId),
            projectId: status.projectId,
          ),
        ),
        // What the flow is doing on its own, and why the next thing may not go
        // as expected — above the box that starts it, in the order each bites:
        // a publish in flight, then your own slot, then nobody to run it.
        if (publishing) ...[
          const SizedBox(height: 10),
          const CodeNotice(
            icon: Icons.cloud_upload_outlined,
            message: 'Publishing your finished task to the team…',
          ),
        ],
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
            constraints: const BoxConstraints(maxWidth: kTranscriptColumnWidth),
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

/// Opens the side panel — the project's copy on this computer, browsable, its
/// changes reviewable, a terminal in it. The same right-panel toggle the chat's
/// top bar carries, here beside the project's own tools.
class _PanelToggle extends ConsumerWidget {
  const _PanelToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final open = ref.watch(codeSidePanelOpenProvider);
    return IconButton(
      tooltip: open ? 'Hide the code panel' : 'Open the code panel',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      isSelected: open,
      color: AppPalette.textSecondary,
      icon: const Icon(LucideIcons.panelRight300),
      onPressed: () => ref.read(codeSidePanelOpenProvider.notifier).toggle(),
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
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
    );
  }
}

/// The toast tier for a thing the flow reported.
ToastSeverity _severity(FlowLevel level) => switch (level) {
  FlowLevel.info => ToastSeverity.info,
  FlowLevel.success => ToastSeverity.success,
  FlowLevel.warning => ToastSeverity.warning,
  FlowLevel.error => ToastSeverity.error,
};
