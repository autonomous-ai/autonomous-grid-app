import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/project.dart';

/// Edit the standing rules the assistant follows in a project's chats — the
/// app's plain-language take on a repo's `AGENTS.md`.
Future<void> showProjectInstructionsDialog(
  BuildContext context,
  Project project,
) => showDialog<void>(
  context: context,
  builder: (_) => _ProjectInstructionsDialog(project: project),
);

class _ProjectInstructionsDialog extends ConsumerStatefulWidget {
  const _ProjectInstructionsDialog({required this.project});

  final Project project;

  @override
  ConsumerState<_ProjectInstructionsDialog> createState() =>
      _ProjectInstructionsDialogState();
}

class _ProjectInstructionsDialogState
    extends ConsumerState<_ProjectInstructionsDialog> {
  late final _rules = TextEditingController(text: widget.project.instructions);

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  void _save() {
    ref
        .read(projectsProvider.notifier)
        .setInstructions(widget.project.id, _rules.text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rules for "${widget.project.name}"',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Standing guidance the assistant reads at the start of every chat in '
            'this project — like a note pinned to the folder.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              LabeledField(
                label: 'Instructions',
                controller: _rules,
                hint:
                    'e.g. Answer in Vietnamese. This is a Flutter app — prefer '
                    'Dart idioms and keep replies short.',
                autofocus: true,
                minLines: 6,
                maxLines: 14,
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
