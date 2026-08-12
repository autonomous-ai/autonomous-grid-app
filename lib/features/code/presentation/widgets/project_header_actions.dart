import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/grid_paths.dart';
import '../../../../infrastructure/cli/host_shell_service.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_argv.dart';
import '../../logic/project_actions.dart';
import '../../logic/project_status.dart';
import 'members_dialog.dart';

/// The quiet things a member can do to the project itself, off to the side of
/// the conversation: open the code on this computer, and see who else is in it.
///
/// Catching up, publishing and getting a copy all used to live here as buttons.
/// The first two are gone — [ProjectFlow] does them around each task. The copy
/// is gone as a *chore* too: the app keeps a working checkout at a fixed place
/// (`~/.grid/app/code/<project>`) and refreshes it whenever a task ships, so all
/// that's left is opening it. Kept deliberately quiet (text, not filled buttons)
/// so these read as tools beside the conversation rather than the point of the
/// screen.
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

  /// The fixed, app-owned place this project's code lives on disk. No folder
  /// picker: the copy is not the user's to file away, it is the app's to keep
  /// current — the same path [ProjectFlow] refreshes after a task ships.
  String get _copyDir {
    final folder = cloneFolderName(
      projectName: widget.projectName ?? '',
      projectId: widget.status.projectId,
    );
    return GridPaths.projectCodeDir(folder).path;
  }

  /// Make sure the copy exists and is current, then open it. `clone` creates the
  /// folder the first time and re-clones into its own the times after, so this
  /// one button both fetches the code and opens where it already is.
  Future<void> _openCopy() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(projectActionsProvider)
          .clone(widget.status.projectId, _copyDir);
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
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        onPressed: _busy ? null : _openCopy,
        icon: const Icon(Icons.folder_open_outlined, size: 16),
        label: const Text('Open the copy'),
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
