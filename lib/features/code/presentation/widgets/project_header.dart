import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../infrastructure/cli/host_shell_service.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/anchored_menu_position.dart';
import '../../../../shared/widgets/app_menu_row.dart';
import '../../../../shared/widgets/header_hover_button.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_project.dart';
import '../../logic/code_projects_controller.dart';
import '../../logic/code_workdir.dart';
import '../../logic/project_actions.dart';
import 'members_dialog.dart';

const _menuWidth = 208.0;
const _rowHeight = 30.0;

/// The menu's own vertical padding — [appMenuStyle]'s `vertical: 5`. Read off
/// that style rather than guessed: the two drifting apart is what pushes a menu
/// off its button.
const _menuPadding = 5.0;

/// Each row's 1px breathing room above and below, which [AppMenuRow] adds
/// outside [_rowHeight].
const _rowGap = 1.0;

/// What the menu will measure, summed rather than estimated so
/// [anchoredMenuPosition] lands it *on* the button instead of near it.
const _menuSize = Size(
  _menuWidth,
  _menuPadding * 2 + (_rowHeight + _rowGap * 2) * 2,
);

/// Names the project you're looking at: a mark, its name, and the "…" that acts
/// on it.
///
/// The chat header's twin, in the same row of the same bar and built from the
/// same parts — the two halves of the app name what you have open the same way,
/// so neither reads as a different product. It replaces a headline, a subtitle
/// and a row of text buttons inside the pane, which pushed the conversation a
/// third of the way down the screen to say things the rail already says.
///
/// Absent until a project is open; [CodePane] shows its own empty screens then.
class ProjectHeader extends ConsumerWidget {
  const ProjectHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The strip tints from a global the element tree can't track, so subscribe
    // to the brightness directly.
    AppTheme.watch(context);
    final projectId = ref.watch(selectedCodeProjectProvider);
    if (projectId == null) return const SizedBox.shrink();
    final project = ref.watch(openCodeProjectProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          LucideIcons.folderGit2300,
          size: 16,
          color: AppPalette.textSecondary,
        ),
        const SizedBox(width: 9),
        // Bounded, not Expanded: the name should sit beside its "…" like a label
        // on a tab, not stretch the menu button out to the far edge of a wide
        // window.
        Flexible(
          child: Text(
            project?.name ?? 'Project',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13.5,
              fontWeight: AppFont.medium,
            ),
          ),
        ),
        const SizedBox(width: 4),
        ProjectHeaderMenuButton(projectId: projectId, project: project),
      ],
    );
  }
}

/// The "…" on the header: open this project's copy on this computer, or see who
/// else is in it.
///
/// The quiet things a member can do to the project *itself*, as opposed to
/// asking for a task — which is the box at the foot of the screen. They were
/// text buttons in a row of their own; catching up and publishing had already
/// left it ([ProjectFlow] does both around each task), and two buttons are not a
/// toolbar, they are a menu that hadn't been written yet.
class ProjectHeaderMenuButton extends ConsumerStatefulWidget {
  const ProjectHeaderMenuButton({
    super.key,
    required this.projectId,
    required this.project,
  });

  final String projectId;

  /// What the grid says about it, or null while the list is still coming: the
  /// copy's folder is named after the project, and admitting people is the
  /// owner's call.
  final GridProject? project;

  @override
  ConsumerState<ProjectHeaderMenuButton> createState() =>
      _ProjectHeaderMenuButtonState();
}

class _ProjectHeaderMenuButtonState
    extends ConsumerState<ProjectHeaderMenuButton> {
  final _menu = MenuController();

  /// Held while the clone is out, so a second press cannot start a second one.
  ///
  /// Not `setState`d: nothing on screen reads it — the menu that carries the row
  /// is already closed by then — and a rebuild for a field no build looks at is
  /// a frame nobody asked for.
  bool _busy = false;

  /// The fixed, app-owned place this project's code lives on disk. No folder
  /// picker: the copy is not the user's to file away, it is the app's to keep
  /// current — the same path [ProjectFlow] refreshes after a task ships.
  String get _copyDir => projectClonePath(
    projectName: widget.project?.name ?? '',
    projectId: widget.projectId,
  );

  /// Make sure the copy exists and is current, then open it. `clone` creates the
  /// folder the first time and re-clones into its own the times after, so this
  /// one row both fetches the code and opens where it already is.
  Future<void> _openCopy() async {
    _menu.close();
    if (_busy) return;
    _busy = true;
    try {
      final result = await ref
          .read(projectActionsProvider)
          .clone(widget.projectId, _copyDir);
      await ref.read(hostShellServiceProvider).openFolder(result.path);
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(
          message: result.startedFromTrunk
              ? 'Opened your copy at ${result.path}. Nothing of yours has '
                    'landed yet, so it starts at ${result.trunk}.'
              : 'Opened your copy at ${result.path}.',
          severity: ToastSeverity.success,
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(message: '$error', severity: ToastSeverity.error),
      );
    } finally {
      _busy = false;
    }
  }

  void _showMembers() {
    _menu.close();
    showMembersDialog(
      context,
      projectId: widget.projectId,
      // Admitting people is the owner's call, so the invite behind this only
      // appears where pressing it would work.
      canInvite: widget.project?.isOwner ?? false,
    );
  }

  void _toggle(BuildContext context) {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    // Right-aligned: the button sits at the name's trailing edge, so a menu
    // growing rightwards from it would hang over the transcript.
    _menu.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize,
        margin: 8,
        gap: 6,
        alignEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      // The shared surface, not a hand-rolled one: the bar sits on the window,
      // and the themed default lands within 1.02:1 of it — in light both are
      // white, which is a menu with no edge at all.
      style: appMenuStyle().copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: _menuPadding),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
      ),
      menuChildren: [
        SizedBox(
          width: _menuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // No "Opening…" state on the row: the menu closes the moment it
              // is pressed, so a label swapped underneath is a label nobody can
              // read. [_busy] is still what stops a second clone starting — the
              // row can be pressed again as soon as the menu reopens.
              AppMenuRow(
                icon: LucideIcons.folderOpen300,
                label: 'Open the copy',
                onPressed: _openCopy,
              ),
              AppMenuRow(
                icon: LucideIcons.users300,
                label: 'Who is in it',
                onPressed: _showMembers,
              ),
            ],
          ),
        ),
      ],
      builder: (context, controller, _) => HeaderHoverButton(
        icon: LucideIcons.ellipsis300,
        tooltip: 'Project options',
        semanticsLabel: 'Project options',
        onTap: () => _toggle(context),
      ),
    );
  }
}
