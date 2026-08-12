import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/host_shell_service.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_argv.dart';
import '../../logic/project_actions.dart';
import '../../logic/project_status.dart';
import 'members_dialog.dart';

/// The quiet things a member can do to the project itself, off to the side of
/// the conversation: get the code onto this computer, and see who else is in it.
///
/// Catching up and publishing used to live here as buttons. They are gone:
/// [ProjectFlow] does both around each task, so the two that remain are the ones
/// that aren't part of asking for a change — a local checkout, and the member
/// list. Kept deliberately quiet (text, not filled buttons) so they read as
/// tools beside the conversation rather than the point of the screen.
class ProjectHeaderActions extends ConsumerStatefulWidget {
  const ProjectHeaderActions({
    super.key,
    required this.status,
    this.projectName,
    this.canInvite = false,
  });

  final ProjectStatus status;

  /// What the project is called, which is what its folder on this computer is
  /// named. Null when the grid hasn't said — the copy then lands in a folder
  /// named after the project's id, which is still a folder of its own.
  final String? projectName;

  /// Whether this member may admit people — the owner's call, so the invite
  /// button behind "Who is in it" only appears where pressing it would work.
  final bool canInvite;

  @override
  ConsumerState<ProjectHeaderActions> createState() =>
      _ProjectHeaderActionsState();
}

class _ProjectHeaderActionsState extends ConsumerState<ProjectHeaderActions> {
  /// Held while the clone is out, so a second press cannot start a second one.
  bool _busy = false;

  Future<void> _getCopy() async {
    final folder = await getDirectoryPath(confirmButtonText: 'Put it here');
    if (folder == null || !mounted || _busy) return;
    // The picker asks where to *put* the copy, and the CLI takes the clone's own
    // directory — so the project gets a folder of its own inside what they
    // chose, the way `git clone` does. Handing the chosen folder straight
    // through pointed the clone at whatever else was already in it.
    final destination = cloneDestination(
      parent: folder,
      projectName: widget.projectName ?? '',
      projectId: widget.status.projectId,
    );
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(projectActionsProvider)
          .clone(widget.status.projectId, destination);
      await ref.read(hostShellServiceProvider).openFolder(result.path);
      if (!mounted) return;
      ToastScope.show(
        context,
        ToastSpec(
          message: result.startedFromTrunk
              ? 'Copied to ${result.path}. Nothing of yours has landed yet, so '
                    'it starts at ${result.trunk}.'
              : 'Copied to ${result.path}, on your own branch.',
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
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        onPressed: _busy ? null : _getCopy,
        icon: const Icon(Icons.download_outlined, size: 16),
        label: const Text('Get a copy'),
      ),
      TextButton.icon(
        onPressed: () => showMembersDialog(
          context,
          projectId: widget.status.projectId,
          canInvite: widget.canInvite,
        ),
        icon: const Icon(Icons.people_outline_rounded, size: 16),
        label: const Text('Who is in it'),
      ),
    ],
  );
}
