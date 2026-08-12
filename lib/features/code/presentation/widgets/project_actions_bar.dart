import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/host_shell_service.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_argv.dart';
import '../../logic/integration.dart';
import '../../logic/project_actions.dart';
import '../../logic/project_status.dart';
import 'confirm_dialogs.dart';
import 'project_status_card.dart';

/// What a member can do to the project itself: take the team's changes, share
/// their own, and get a working copy on this computer.
///
/// The two that move refs are guarded differently and on purpose. Catching up
/// is asked about first — the grid answers "would this conflict" for free, and
/// the paid answer is an agent run. Publishing is confirmed loudly, because it
/// is the one action here with **no undo**.
class ProjectActionsBar extends ConsumerStatefulWidget {
  const ProjectActionsBar({super.key, required this.status, this.projectName});

  final ProjectStatus status;

  /// What the project is called, which is what its folder on this computer is
  /// named. Null when the grid hasn't said — the copy then lands in a folder
  /// named after the project's id, which is still a folder of its own.
  final String? projectName;

  @override
  ConsumerState<ProjectActionsBar> createState() => _ProjectActionsBarState();
}

class _ProjectActionsBarState extends ConsumerState<ProjectActionsBar> {
  /// Held while a command is out, so a second press cannot start a second one.
  /// A task slot is a real resource; a double-click on Catch up could spend it
  /// on two agent runs.
  bool _busy = false;

  ProjectStatus get _status => widget.status;

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        ToastScope.show(
          context,
          ToastSpec(message: '$error', severity: ToastSeverity.error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _catchUp() => _guard(() async {
    final actions = ref.read(projectActionsProvider);
    // Ask for free before spending anything: on a conflict, doing it queues a
    // paid agent run and takes this member's one task slot.
    final preview = await actions.check(_status.projectId);
    if (!mounted) return;
    if (preview.status == IntegrationStatus.upToDate) {
      ToastScope.show(
        context,
        const ToastSpec(message: 'Already up to date with the team.'),
      );
      return;
    }
    final go = await confirmCatchUp(context, preview);
    if (!go || !mounted) return;
    final result = await actions.integrate(_status.projectId);
    if (!mounted) return;
    ToastScope.show(context, ToastSpec(message: _caughtUp(result)));
  });

  static String _caughtUp(IntegrationResult result) => switch (result.status) {
    IntegrationStatus.upToDate => 'Already up to date with the team.',
    IntegrationStatus.fastForward || IntegrationStatus.merged =>
      'Your copy now has the team’s work '
          '(${shortCommit(result.commit ?? '')}).',
    // Nothing has moved yet — an agent is about to. Saying "caught up" here
    // would be a claim about work that has not started.
    IntegrationStatus.mergeTask =>
      'You and someone else changed the same lines, so a task is resolving it. '
          'Read what it did before you publish.',
    IntegrationStatus.unknown =>
      'The grid answered in a way this app could '
          'not read.',
  };

  Future<void> _publish() => _guard(() async {
    final memberKey = _status.memberKey;
    if (memberKey == null) {
      ToastScope.show(
        context,
        const ToastSpec(
          message:
              'The grid did not say which member you are here, so there '
              'is no branch to publish.',
          severity: ToastSeverity.error,
        ),
      );
      return;
    }
    final go = await confirmPublish(context, _status);
    if (!go || !mounted) return;
    final result = await ref
        .read(projectActionsProvider)
        .promote(_status.projectId, memberKey);
    if (!mounted) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: result.advanced
            ? 'Published. The team’s copy is now at '
                  '${shortCommit(result.commit ?? '')}.'
            : 'Nothing to publish — the team already has this.',
        severity: ToastSeverity.success,
      ),
    );
  });

  Future<void> _getCopy() async {
    final folder = await getDirectoryPath(confirmButtonText: 'Put it here');
    if (folder == null || !mounted) return;
    // The picker asks where to *put* the copy, and the CLI takes the clone's own
    // directory — so the project gets a folder of its own inside what they
    // chose, the way `git clone` does. Handing the chosen folder straight
    // through pointed the clone at whatever else was already in it.
    final destination = cloneDestination(
      parent: folder,
      projectName: widget.projectName ?? '',
      projectId: _status.projectId,
    );
    await _guard(() async {
      final result = await ref
          .read(projectActionsProvider)
          .clone(_status.projectId, destination);
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final canPublish = _status.canPromote == true;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton(
          onPressed: _busy ? null : _catchUp,
          child: const Text('Catch up with the team'),
        ),
        Tooltip(
          message: canPublish
              ? 'Move the team’s copy to your work. This cannot be undone.'
              : 'Catch up first — the team has changes you don’t have yet.',
          child: FilledButton(
            onPressed: (_busy || !canPublish) ? null : _publish,
            child: const Text('Publish to the team'),
          ),
        ),
        OutlinedButton(
          onPressed: _busy ? null : _getCopy,
          child: const Text('Get a copy on this computer'),
        ),
      ],
    );
  }
}
