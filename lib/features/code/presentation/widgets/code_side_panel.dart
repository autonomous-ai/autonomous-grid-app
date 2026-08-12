import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../files/presentation/files_panel_view.dart';
import '../../../projects/logic/project.dart';
import '../../../review/presentation/review_surface.dart';
import '../../../terminal/presentation/terminal_panel_view.dart';
import '../../logic/code_side_panel.dart';
import '../../logic/code_workdir.dart';
import '../../logic/project_actions.dart';

/// The panel beside a project's conversation: its local clone, browsable, its
/// git changes reviewable, and a terminal that opens in it — the same three
/// tools the chat carries, rooted here at `~/.grid/app/code/<project>` (the copy
/// the flow keeps current) instead of the chat's workspace.
///
/// The chat's own panels are woven into its composer — "add to chat", "ask the
/// assistant", snippets — none of which a task-driven project has, so this
/// mounts the feature *surfaces* directly with those hooks left off. What Review
/// does offer, "ask about this", goes to the task box below through
/// [codeComposerPrefillProvider], the one thing that maps cleanly.
class CodeSidePanel extends ConsumerWidget {
  const CodeSidePanel({
    super.key,
    required this.projectId,
    required this.projectName,
  });

  final String projectId;
  final String? projectName;

  String get _clonePath =>
      projectClonePath(projectName: projectName ?? '', projectId: projectId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final path = _clonePath;
    final exists = ref.watch(codeCloneExistsProvider(path));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        border: Border(left: BorderSide(color: AppPalette.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TabStrip(),
          const Divider(height: 1),
          Expanded(
            child: switch (exists) {
              AsyncData(value: true) => _Surfaces(
                projectId: projectId,
                projectName: projectName,
                clonePath: path,
              ),
              AsyncData(value: false) => _NoCopyYet(
                projectId: projectId,
                clonePath: path,
              ),
              AsyncError() => _NoCopyYet(projectId: projectId, clonePath: path),
              _ => const LoadingView(),
            },
          ),
        ],
      ),
    );
  }
}

/// Files / Review / Terminal, with a close button — the panel's own chrome, not
/// the dynamic multi-tab strip the chat has, since a project's copy is one place
/// with three views of it.
class _TabStrip extends ConsumerWidget {
  const _TabStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final current = ref.watch(codeSidePanelTabProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      child: Row(
        children: [
          for (final tab in CodePanelTab.values) ...[
            _TabButton(
              label: tab.label,
              selected: tab == current,
              onTap: () =>
                  ref.read(codeSidePanelTabProvider.notifier).select(tab),
            ),
            const SizedBox(width: 4),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Close',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            color: AppPalette.textFaint,
            icon: const Icon(Icons.close_rounded),
            onPressed: () =>
                ref.read(codeSidePanelOpenProvider.notifier).close(),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Material(
      color: selected ? AppSurface.hoverFill : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? AppFont.medium : FontWeight.w400,
              color: selected
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The three surfaces, all mounted so switching a tab keeps a terminal's
/// scrollback and Files' open folders — the same reason the chat keeps its tabs
/// built.
class _Surfaces extends ConsumerWidget {
  const _Surfaces({
    required this.projectId,
    required this.projectName,
    required this.clonePath,
  });

  final String projectId;
  final String? projectName;
  final String clonePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(codeSidePanelTabProvider);
    return IndexedStack(
      index: tab.index,
      children: [
        FilesPanelView(
          tabId: 'code-files-$projectId',
          folder: clonePath,
          folderLabel: projectName ?? 'This project',
          // No conversation to open a file into, or to quote a selection to,
          // and one place means no "open in a new tab".
          onOpenInNewTab: null,
          onAddToChat: null,
          onAddSelection: null,
        ),
        ReviewSurface(
          project: Project(
            id: projectId,
            name: projectName ?? 'This project',
            path: clonePath,
          ),
          onClose: () => ref.read(codeSidePanelOpenProvider.notifier).close(),
          // The one hook a task project has: a request goes to the box below,
          // where the grid picks who runs it, rather than off on its own.
          onAskAgent: (message) =>
              ref.read(codeComposerPrefillProvider.notifier).offer(message),
          onAddSelection: null,
          onAddFile: null,
        ),
        TerminalPanelView(
          tabId: 'code-term-$projectId',
          workdir: clonePath,
          // The panel is mounted whenever this builds, so the shell is on screen
          // exactly when the Terminal tab is the one selected.
          showing: tab == CodePanelTab.terminal,
          onAddToChat: null,
        ),
      ],
    );
  }
}

/// The copy hasn't been fetched yet, so there is nothing to browse, review, or
/// run a terminal in. Offer to fetch it — the same clone the header button and
/// the flow use, at the same fixed path.
class _NoCopyYet extends ConsumerStatefulWidget {
  const _NoCopyYet({required this.projectId, required this.clonePath});

  final String projectId;
  final String clonePath;

  @override
  ConsumerState<_NoCopyYet> createState() => _NoCopyYetState();
}

class _NoCopyYetState extends ConsumerState<_NoCopyYet> {
  bool _busy = false;

  Future<void> _fetch() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(projectActionsProvider)
          .clone(widget.projectId, widget.clonePath);
      ref.invalidate(codeCloneExistsProvider(widget.clonePath));
    } on Object catch (error) {
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(message: '$error', severity: ToastSeverity.error),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.folderDown300,
    title: 'No copy on this computer yet',
    message:
        'Bring the project’s code down to browse it, review its changes and '
        'open a terminal in it. It lands at ${widget.clonePath}.',
    action: FilledButton(
      onPressed: _busy ? null : _fetch,
      child: Text(_busy ? 'Fetching…' : 'Get the code'),
    ),
  );
}
