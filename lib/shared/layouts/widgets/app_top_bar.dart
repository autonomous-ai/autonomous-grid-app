import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/chat/logic/bottom_panel.dart';
import '../../../features/chat/logic/chat_rail.dart';
import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/logic/preview_panel.dart';
import '../../../features/chat/logic/workflow_bubble_open.dart';
import '../../../features/chat/presentation/chat_header.dart';
import '../../../features/code/logic/code_projects_controller.dart';
import '../../../features/code/logic/code_side_panel.dart';
import '../../../features/code/logic/project_status_controller.dart';
import '../../../features/code/presentation/widgets/project_header.dart';
import '../../../features/node_setup/logic/background_model_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_spinner.dart';
import '../../widgets/panel_toggle.dart';
import '../shell_state.dart';
import 'grid_power_pill.dart';
import 'top_bar_pill.dart';
import 'working_now_pill.dart';

/// The slim strip above the open section: on the left, the conversation you're
/// reading; on the right, which grid is active and what it has behind it
/// (computers hosting, models served, the hardware they bring), plus any model
/// the user is downloading. Doubles as the window's drag handle.
///
/// The chat header shares this row rather than owning a strip below it — two
/// stacked bars put the chat's title and the grid's summary a few pixels out of
/// line with each other, which read as a mistake. One row, one baseline.
///
/// Deliberately quiet — the account, the grid switcher and the navigation all
/// live in the sidebar, so nothing competes with the conversation below.
class AppTopBar extends ConsumerWidget {
  const AppTopBar({super.key});

  static const double height = 46;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The hairline below tints from a global the element tree can't track, so
    // subscribe to the brightness here rather than relying on an ancestor's
    // watch — it wouldn't reach across the const children below.
    AppTheme.watch(context);
    // Only the chat view knows whether its header applies (a model is
    // reachable, and the chat is past its starters screen).
    final showChatHeader =
        ref.watch(chatIsOpenProvider) && ref.watch(chatHeaderVisibleProvider);
    // The other half's header, in the same slot: a project is named here the
    // way a conversation is, rather than under a headline of its own inside the
    // pane.
    final showProjectHeader = ref.watch(codeProjectIsOpenProvider);
    final showHeader = showChatHeader || showProjectHeader;
    return DragToMoveArea(
      child: DecoratedBox(
        // Only under a named conversation — a chat's or a project's. The bar is
        // otherwise seamless with the pane, and a rule under an empty bar would
        // divide nothing; but a transcript needs to start against an edge rather
        // than float up into the window chrome.
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: showHeader ? AppPalette.divider : Colors.transparent,
            ),
          ),
        ),
        child: SizedBox(
          height: height,
          // Seamless with the content, like Codex — no fill, no blur. The pills
          // simply float on the pane; the bar is just their row and the window's
          // drag handle. Each pill stays unmounted when it has nothing to show,
          // so an idle grid leaves the bar empty rather than showing a bare
          // capsule.
          child: Padding(
            // A fixed inset either way: the rail is always there — folded it is
            // [AppSidebarMini], wide enough to keep the macOS traffic lights on
            // its own fill — so the bar never becomes the window's left edge and
            // never has to clear them. It also has no expand button of its own
            // any more: the fold toggle lives on the rail, in both states, so
            // there is one place it can be.
            padding: const EdgeInsets.only(left: 16, right: 18),
            child: Row(
              children: [
                // One flex child, not two. An Expanded header *plus* a Spacer
                // both take flex: 1 and split the free space between them,
                // which parks the grid pill mid-row instead of against the
                // right edge. The header owns the whole left side and aligns
                // its own content; the pills sit at their intrinsic width on
                // the right.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: switch ((showChatHeader, showProjectHeader)) {
                      (true, _) => const ChatHeader(),
                      (_, true) => const ProjectHeader(),
                      _ => const SizedBox.shrink(),
                    },
                  ),
                ),
                // Leftmost of the pills, furthest from the panel toggles: it is
                // the only one about work the user started, and the only one
                // they may want to act on.
                const WorkingNowPill(),
                const _ModelDownloadPill(),
                const GridPowerPill(),
                const _WorkflowBubbleToggle(),
                const _ProjectRailToggle(),
                const _BottomPanelToggle(),
                const _SidePanelToggle(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows and hides the workflow bubble — the top-bar entry point into the
/// orchestration overview.
///
/// Right beside [GridPowerPill] rather than with the panel toggles: it isn't a
/// panel around the conversation, it's a small indicator of its own, and it
/// belongs next to the grid summary it reports on.
class _WorkflowBubbleToggle extends ConsumerWidget {
  const _WorkflowBubbleToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(workflowBubbleOpenProvider);
    return PanelToggle(
      icon: LucideIcons.workflow,
      open: open,
      label: 'orchestration overview',
      onPressed: () => ref.read(workflowBubbleOpenProvider.notifier).toggle(),
    );
  }
}

/// Shows and hides the project rail beside a chat — the top-bar counterpart to
/// the panel itself, so a narrow window (where the rail can't sit alongside and
/// opens as an overlay) still has an obvious way in and out.
///
/// Only appears while a project chat is open: a plain chat has no rail to toggle.
class _ProjectRailToggle extends ConsumerWidget {
  const _ProjectRailToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final inChat = ref.watch(chatIsOpenProvider);
    final inProject = ref.watch(
      chatSessionsProvider.select((s) => s.openProjectId != null),
    );
    if (!inChat || !inProject) return const SizedBox.shrink();

    // Mirror the pane's resolved visibility (it alone knows its width); a tap
    // forces the opposite, overriding the smart default until the next chat.
    final visible = ref.watch(chatRailVisibleProvider);
    return PanelToggle(
      icon: visible ? Icons.vertical_split : Icons.vertical_split_outlined,
      open: visible,
      // "Project panel", not "rail": the word on the button has to be the word
      // the user would use for the thing that appears.
      label: 'project panel',
      leading: 8,
      onPressed: () =>
          ref.read(chatRailOverrideProvider.notifier).set(!visible),
    );
  }
}

/// Opens and closes the bottom panel — the strip under the conversation.
///
/// Between the two side toggles because that is the order the panels sit in
/// around the chat, read clockwise from the left edge; a row of toggles whose
/// order doesn't match the thing they move is a row you have to read twice.
class _BottomPanelToggle extends ConsumerWidget {
  const _BottomPanelToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_chatWithGrid(ref)) return const SizedBox.shrink();

    final open = ref.watch(bottomPanelOpenProvider);
    return PanelToggle(
      icon: LucideIcons.panelBottom,
      open: open,
      label: 'bottom panel',
      onPressed: () => ref.read(bottomPanelOpenProvider.notifier).toggle(),
    );
  }
}

/// Opens and closes the panel beside the conversation — the chat's, or the one
/// beside a Code project.
///
/// One button for both, because it is one panel: the same tabs, the same
/// launcher, the same three surfaces, rooted at whichever folder the screen is
/// about. A second toggle inside the project's pane was the same control in a
/// different place wearing a different style.
class _SidePanelToggle extends ConsumerWidget {
  const _SidePanelToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(codeProjectIsOpenProvider)) {
      // A project with no repository in it has nothing to browse, review or run
      // a terminal in — see [openProjectHasCodeProvider].
      if (!ref.watch(openProjectHasCodeProvider)) {
        return const SizedBox.shrink();
      }
      final open = ref.watch(codeSidePanelOpenProvider);
      return PanelToggle(
        icon: LucideIcons.panelRight,
        open: open,
        label: 'code panel',
        onPressed: () => ref.read(codeSidePanelOpenProvider.notifier).toggle(),
      );
    }

    if (!_chatWithGrid(ref)) return const SizedBox.shrink();
    final open = ref.watch(previewPanelOpenProvider);
    return PanelToggle(
      icon: LucideIcons.panelRight,
      open: open,
      label: 'preview panel',
      onPressed: () => ref.read(previewPanelOpenProvider.notifier).toggle(),
    );
  }
}

/// Whether a panel toggle has anything to toggle.
///
/// Neither panel waits for a project the way the rail does — any chat can open
/// a terminal or a review. Both wait for a grid: without one the pane is a nudge
/// to pick one, and a button that moves nothing is worse than no button.
bool _chatWithGrid(WidgetRef ref) =>
    ref.watch(chatIsOpenProvider) && ref.watch(selectedNetworkProvider) != null;

/// The background model download, shown in the top bar so a user who went
/// straight into chat can see their own model arriving. Nothing when idle or
/// done; on a failure it becomes a tap-through to the Engines tab to retry.
class _ModelDownloadPill extends ConsumerWidget {
  const _ModelDownloadPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(backgroundModelControllerProvider)) {
      ModelDownloadRunning(:final progress) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: TopBarPill(child: _DownloadingLabel(pct: progress?.pct)),
      ),
      ModelDownloadFailed() => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Tooltip(
          message: 'Open Engines to try again',
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.engines),
            child: const TopBarPill(child: _DownloadFailedLabel()),
          ),
        ),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _DownloadingLabel extends StatelessWidget {
  const _DownloadingLabel({required this.pct});

  final double? pct;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final pct = this.pct;
    final label = pct == null
        ? 'Downloading model…'
        : 'Downloading model · ${pct.round()}%';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppSpinner(size: SpinnerSize.small),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _DownloadFailedLabel extends StatelessWidget {
  const _DownloadFailedLabel();

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 14, color: error),
        const SizedBox(width: 6),
        Text(
          'Model download failed',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: error,
          ),
        ),
      ],
    );
  }
}
