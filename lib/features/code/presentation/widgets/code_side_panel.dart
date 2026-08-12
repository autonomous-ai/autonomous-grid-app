import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/panels/panel_surface.dart';
import '../../../../shared/panels/panel_tabs.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_side_panel.dart';
import '../../logic/code_workdir.dart';
import '../../logic/project_actions.dart';
import 'code_panel_feature_view.dart';

/// The panel beside a project's conversation: its local clone, browsable, its
/// git changes reviewable, and a terminal that opens in it.
///
/// The *same* panel as the one beside a chat — [PanelSurface] draws the tabs,
/// the launcher and the "+" for both — rooted here at the project's folder
/// under `~/.grid/app/code` (the copy the flow keeps current) instead of the
/// chat's workspace. It used to be a lookalike with plain text tabs, no
/// launcher and a close button the chat's panel doesn't have — two things to
/// learn for one idea.
class CodeSidePanel extends ConsumerWidget {
  const CodeSidePanel({
    super.key,
    required this.projectId,
    required this.projectName,
    this.onRaisedSurface = false,
  });

  final String projectId;
  final String? projectName;

  /// Set when the panel is floating over the conversation rather than docked
  /// beside it — see [PanelSurface.onRaisedSurface].
  final bool onRaisedSurface;

  /// What to call the copy wherever it is shown — the project's own name, since
  /// the path under `~/.grid` is one the app chose rather than a word the user
  /// knows.
  String get _label => projectName ?? 'This project';

  String get _clonePath =>
      projectClonePath(projectName: projectName ?? '', projectId: projectId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = _clonePath;
    // Before the panel's own chrome, not inside a tab: with no copy on disk
    // there is nothing to browse, review or run a terminal in, so a strip of
    // tabs over three empty surfaces would be chrome around nothing.
    return switch (ref.watch(codeCloneExistsProvider(path))) {
      AsyncData(value: true) => PanelSurface(
        host: PanelHost.code,
        onRaisedSurface: onRaisedSurface,
        viewBuilder: (tab, {required onClose}) => codePanelFeatureView(
          tab,
          onClose: onClose,
          projectId: projectId,
          projectName: _label,
          clonePath: path,
        ),
      ),
      AsyncData(value: false) => _NoCopyYet(
        projectId: projectId,
        clonePath: path,
      ),
      AsyncError() => _NoCopyYet(projectId: projectId, clonePath: path),
      _ => const LoadingView(),
    };
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
