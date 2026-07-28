import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/project.dart';
import 'rail_card.dart';

/// The rail's Memory card: facts the user asks the assistant to remember about
/// this project, added and forgotten in place.
///
/// Where Instructions say *how* to work, Memory says *what's true here* — and
/// both ride along on the agent's first turn (see [projectStandingBrief]), so a
/// remembered fact actually reaches the assistant rather than just sitting in a
/// list.
class ProjectMemoryCard extends ConsumerStatefulWidget {
  const ProjectMemoryCard({required this.project, super.key});

  final Project project;

  @override
  ConsumerState<ProjectMemoryCard> createState() => _ProjectMemoryCardState();
}

class _ProjectMemoryCardState extends ConsumerState<ProjectMemoryCard> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _add() {
    final text = _note.text.trim();
    if (text.isEmpty) return;
    ref.read(projectsProvider.notifier).addMemory(widget.project.id, text);
    _note.clear();
  }

  @override
  Widget build(BuildContext context) {
    final memory =
        ref.watch(projectByIdProvider(widget.project.id))?.memory ??
        widget.project.memory;

    return RailCard(
      icon: Icons.psychology_outlined,
      title: 'Memory',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (memory.isEmpty)
            const RailHint(
              'Nothing remembered yet. Add a fact the assistant should always '
              'know here — "the prod DB is read-only", "release notes go to '
              '#eng".',
            )
          else
            for (var i = 0; i < memory.length; i++)
              _MemoryRow(
                text: memory[i],
                onForget: () => ref
                    .read(projectsProvider.notifier)
                    .removeMemoryAt(widget.project.id, i),
              ),
          const SizedBox(height: 10),
          _AddNote(controller: _note, onAdd: _add),
        ],
      ),
    );
  }
}

/// One remembered fact: a bullet, the fact, and a quiet "forget" affordance.
class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.text, required this.onForget});

  final String text;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 8, left: 2),
            child: Icon(Icons.circle, size: 4, color: AppPalette.textFaint),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Forget this',
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            color: AppPalette.textFaint,
            icon: const Icon(Icons.close_rounded),
            onPressed: onForget,
          ),
        ],
      ),
    );
  }
}

/// The single-line box for remembering one more thing — Enter or the plus adds
/// it, then it clears for the next.
class _AddNote extends StatelessWidget {
  const _AddNote({required this.controller, required this.onAdd});

  final TextEditingController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onAdd(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Remember something…',
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Remember it',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          color: AppPalette.accent,
          icon: const Icon(Icons.add_rounded),
          onPressed: onAdd,
        ),
      ],
    );
  }
}
