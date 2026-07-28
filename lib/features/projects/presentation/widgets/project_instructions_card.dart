import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/project.dart';
import 'rail_card.dart';

/// The rail's Instructions card: the standing house rules the assistant follows
/// in this project's chats, read in place and edited without a dialog.
///
/// The app's plain-language take on a repo's `AGENTS.md` — "answer in
/// Vietnamese", "this is a Flutter app". Shares [ProjectsController.setInstructions]
/// with the list-row editor, so the two never drift.
class ProjectInstructionsCard extends ConsumerStatefulWidget {
  const ProjectInstructionsCard({required this.project, super.key});

  final Project project;

  @override
  ConsumerState<ProjectInstructionsCard> createState() =>
      _ProjectInstructionsCardState();
}

class _ProjectInstructionsCardState
    extends ConsumerState<ProjectInstructionsCard> {
  final _rules = TextEditingController();
  bool _editing = false;

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  void _startEdit(String current) {
    _rules.text = current;
    setState(() => _editing = true);
  }

  void _save() {
    ref
        .read(projectsProvider.notifier)
        .setInstructions(widget.project.id, _rules.text);
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Live, so a save from the list-row dialog shows here without a reselect.
    final rules =
        ref.watch(projectByIdProvider(widget.project.id))?.instructions ??
        widget.project.instructions;

    return RailCard(
      icon: Icons.rule_rounded,
      title: 'Instructions',
      trailing: _editing
          ? null
          : IconButton(
              tooltip: rules.isEmpty ? 'Add rules' : 'Edit rules',
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              color: rules.isEmpty
                  ? AppPalette.textSecondary
                  : AppPalette.accent,
              icon: Icon(
                rules.isEmpty ? Icons.add_rounded : Icons.edit_outlined,
              ),
              onPressed: () => _startEdit(rules),
            ),
      child: _editing ? _editor() : _reader(rules),
    );
  }

  Widget _reader(String rules) {
    if (rules.isEmpty) {
      return const RailHint(
        'No standing rules yet. Add guidance the assistant follows in every '
        'chat here — like a note pinned to the folder.',
      );
    }
    return Text(
      rules,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: AppPalette.textSecondary,
        height: 1.45,
      ),
    );
  }

  Widget _editor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _rules,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          style: const TextStyle(fontSize: 13, height: 1.4),
          decoration: const InputDecoration(
            isDense: true,
            hintText:
                'e.g. Answer in Vietnamese. This is a Flutter app — prefer '
                'Dart idioms and keep replies short.',
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() => _editing = false),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ],
    );
  }
}
