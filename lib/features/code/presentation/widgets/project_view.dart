import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/panels/panel_metrics.dart';
import '../../../../shared/panels/panel_slots.dart';
import '../../../../shared/panels/panel_tabs.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../playground/presentation/transcript_view.dart';
import '../../logic/code_projects_controller.dart';
import '../../logic/code_side_panel.dart';
import '../../logic/project_flow.dart';
import '../../logic/project_status.dart';
import '../../logic/project_status_controller.dart';
import 'code_failure.dart';
import 'code_notice.dart';
import 'code_side_panel.dart';
import 'import_repo_dialog.dart';
import 'task_composer.dart';
import 'task_transcript.dart';

/// What the conversation keeps for itself before the side panel may dock beside
/// it — the chat pane's floor, for the same reason: below it the box at the foot
/// is laid out narrower than its own controls, and the failure mode is stripes
/// across the composer rather than a screen that merely looks tight.
const double kProjectMinWidth = 440;

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
    final project = ref.watch(openCodeProjectProvider);
    final status = ref.watch(projectStatusProvider(projectId));

    // The side panel — the clone browsed, its diff reviewed, a terminal in it —
    // only earns its place once the project has code to work on, and only when
    // the user has asked for it. Read from the same provider the top bar's
    // toggle asks, so the button and the panel can't disagree about whether
    // there is anything to show.
    final panelOpen =
        ref.watch(codeSidePanelOpenProvider) &&
        ref.watch(openProjectHasCodeProvider);
    // Asked for, not yet granted: expanding means the panel takes the pane, and
    // whether it can depends on a width this build hasn't measured yet.
    final expandWanted =
        ref.watch(panelExpandedProvider(PanelHost.code)) && panelOpen;
    // Null until the user drags the seam; the resolver falls back to a share of
    // the pane, which keeps answering to the window's size.
    final override = ref.watch(panelWidthOverrideProvider(PanelHost.code));

    final conversation = switch (status) {
      AsyncData(:final value) when value.needsImport => _NeedsImport(
        projectId: projectId,
      ),
      AsyncData(:final value) => _Conversation(status: value),
      AsyncError(:final error) => CodeFailure(
        message: '$error',
        onRetry: () => ref.invalidate(projectStatusProvider(projectId)),
      ),
      _ => const LoadingView(),
    };
    // No headline and no subtitle: the project is named in the top bar, the way
    // the open chat is, and the transcript starts against that bar's edge
    // instead of a third of the way down the pane. The same slots the chat pane
    // lays its panel out in, so the panel docks, slides, resizes and expands
    // here the way it does there.
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = resolveSidePanel(
          paneWidth: constraints.maxWidth,
          mainMinWidth: kProjectMinWidth,
          override: override,
        );
        // Granted only where there is a docked panel to give the pane to. A
        // floating panel already covers the conversation, so there is nothing
        // to expand *into*.
        final expanded = expandWanted && size.fits;
        // What the conversation is worth with the panel at its normal width.
        // Laid out at this throughout and clipped to its slot, so the panel
        // opening slides the conversation left instead of squeezing it.
        final mainWidth = _atLeast(
          constraints.maxWidth - (panelOpen && size.fits ? size.width : 0),
          kProjectMinWidth,
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: PanelMainSlot(
                width: mainWidth,
                hidden: expanded,
                child: Stack(
                  children: [
                    Positioned.fill(child: conversation),
                    if (!size.fits)
                      Positioned.fill(
                        child: PanelFloatSlot(
                          host: PanelHost.code,
                          open: panelOpen,
                          width: size.width,
                          child: CodeSidePanel(
                            projectId: projectId,
                            projectName: project?.name,
                            onRaisedSurface: true,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (size.fits)
              PanelDockSlot(
                open: panelOpen,
                // Expanded, the slot *is* the pane: the conversation's own
                // slot is flexible, so it takes what is left, which is
                // nothing.
                width: expanded ? constraints.maxWidth : size.width,
                // The panel is on the right, so dragging the seam left — a
                // negative delta — makes it wider. Each report resizes from
                // the width just resolved, which is what makes the clamps
                // hold.
                onResize: (dx) => ref
                    .read(panelWidthOverrideProvider(PanelHost.code).notifier)
                    .set(size.width - dx),
                onResetSize: ref
                    .read(panelWidthOverrideProvider(PanelHost.code).notifier)
                    .reset,
                child: CodeSidePanel(
                  projectId: projectId,
                  projectName: project?.name,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// `a`, but never below `floor`. `clamp` asserts low ≤ high, so a pane laid out
/// narrower than the composer's floor would throw rather than degrade.
double _atLeast(double a, double floor) => a > floor ? a : floor;

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
  const _Conversation({required this.status});

  final ProjectStatus status;

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
        Expanded(
          child: TaskTranscript(
            // Keyed by the project so its scroll and follow state belong to the
            // one on screen, and a switch lands at the new project's newest turn.
            key: ValueKey(status.projectId),
            projectId: status.projectId,
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kTranscriptColumnWidth),
            child: Padding(
              // The chat's inset around the same stack, so the two composers sit
              // the same distance off the foot of the window.
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Where this member's work stands against the team's — a line
                  // rather than a heading, in the run of notices above the box
                  // that changes it. It sat at the top of the pane until the
                  // project's name moved to the top bar, and a lone status line
                  // up there would have been a header made of one fact.
                  _Distance(status: status),
                  // What the flow is doing on its own, and why the next thing may
                  // not go as expected — in the order each bites: a publish in
                  // flight, then your own slot, then nobody to run it.
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
                          '${holder.state.label.toLowerCase()} — a project runs '
                          'one of yours at a time. Stop it above to start '
                          'another.',
                    ),
                  ],
                  if (fleetNotice(status) case final notice?) ...[
                    const SizedBox(height: 10),
                    CodeNotice(message: notice),
                  ],
                  const SizedBox(height: 10),
                  TaskComposer(
                    // Keyed by the project so the box belongs to the one on
                    // screen. Without it the same state is reused across a
                    // switch, and a half-written request would be sitting in
                    // another project's composer with Send under it.
                    key: ValueKey(status.projectId),
                    projectId: status.projectId,
                    slotHeld: holder != null,
                  ),
                ],
              ),
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
