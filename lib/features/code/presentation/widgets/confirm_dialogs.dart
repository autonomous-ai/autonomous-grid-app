import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/integration.dart';
import '../../logic/project_status.dart';

/// Say what catching up would actually do, then ask.
///
/// The free preview is the only reason this can be asked at all: performing the
/// integration *is* the conflict check without it, and on a conflict that check
/// costs an agent run and this member's one task slot.
Future<bool> confirmCatchUp(
  BuildContext context,
  IntegrationPreview preview,
) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (_) => _Confirm(
      title: preview.wouldQueueAgent
          ? 'This needs an agent to sort out'
          : 'Take the team’s changes?',
      body: _catchUpBody(preview),
      confirmLabel: preview.wouldQueueAgent ? 'Let an agent merge it' : 'Do it',
      files: preview.files,
    ),
  );
  return agreed ?? false;
}

String _catchUpBody(IntegrationPreview preview) => switch (preview.status) {
  IntegrationStatus.upToDate =>
    'Your copy already has everything the team has.',
  IntegrationStatus.fastForward =>
    'Your copy moves straight onto the team’s. Nothing is merged and there is '
        'nothing to review.',
  IntegrationStatus.merged =>
    'The team’s work merges into yours cleanly, leaving a merge in your '
        'history.',
  IntegrationStatus.mergeTask =>
    'You and someone else changed the same lines, so this queues a task and an '
        'agent resolves it — using your one task slot, and costing a run on '
        'somebody’s subscription.\n\n'
        'The grid checks that the merge happened. It cannot check that the '
        'answer is right, so read what the agent did before you publish.',
  IntegrationStatus.unknown => 'The grid did not say what this would do.',
};

/// Ask before the trunk moves.
///
/// Loud on purpose. Publishing is the one action in this feature with **no
/// undo** in this release: the commit it replaces is recorded, and putting it
/// back is an operation on the relay itself. Code an agent wrote reaches the
/// team the moment this goes through.
Future<bool> confirmPublish(BuildContext context, ProjectStatus status) async {
  final ahead = status.ahead;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (_) => _Confirm(
      title: 'Publish your work to the team?',
      body:
          'This moves the team’s copy to yours'
          '${ahead == null ? '' : ', bringing $ahead change'
                    '${ahead == 1 ? '' : 's'} with it'}.\n\n'
          'It cannot be undone from this app, and an agent’s code reaches '
          'everyone the moment it lands. Read the work first if you have not '
          'already — “Get a copy on this computer” is how.',
      confirmLabel: 'Publish',
      destructive: true,
    ),
  );
  return agreed ?? false;
}

/// A plain confirm: a sentence about what will happen, and the two answers.
class _Confirm extends StatelessWidget {
  const _Confirm({
    required this.title,
    required this.body,
    required this.confirmLabel,
    this.files = const [],
    this.destructive = false,
  });

  final String title;
  final String body;
  final String confirmLabel;

  /// Paths a conflict would touch. The grid sends them as data precisely so
  /// they need not be dug out of a sentence.
  final List<String> files;

  final bool destructive;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 12, 22, 22),
      title: Text(
        title,
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                body,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: AppPalette.textSecondary,
                ),
              ),
              if (files.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'Files in question',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: AppFont.medium,
                    letterSpacing: 0.6,
                    color: AppPalette.textFaint,
                  ),
                ),
                const SizedBox(height: 6),
                for (final path in files)
                  Text(
                    path,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      fontFamily: AppFont.mono,
                      fontFamilyFallback: AppFont.monoFallback,
                      color: AppPalette.textSecondary,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
