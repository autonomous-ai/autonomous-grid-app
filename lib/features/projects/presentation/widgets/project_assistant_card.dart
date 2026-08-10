import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../agents/logic/agent_catalog.dart';
import '../../../agents/presentation/agent_mark.dart';
import '../../logic/project.dart';
import 'rail_card.dart';

/// The rail's Assistant card: who answers this project's chats and what they
/// answer with.
///
/// Read-only on purpose. Both are picked where they're used — in the composer at
/// the foot of a chat in this project, beside the message being typed — and a
/// second set of pickers here would be a second place to keep in step, on a
/// screen with no grid open to list models from. What this card is *for* is the
/// other half: showing a user who wondered why the assistant changed between
/// projects that it is this project's own choice, and giving them one way back
/// to the app's default.
class ProjectAssistantCard extends ConsumerWidget {
  const ProjectAssistantCard({required this.project, super.key});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read live rather than off the passed project: a pick made in a chat in
    // this project has to show here without the rail being reopened.
    final current = ref.watch(projectByIdProvider(project.id)) ?? project;
    final agent = agentToolById(current.agent);
    final model = current.model;
    final picked = agent != null || model != null;

    return RailCard(
      icon: Icons.smart_toy_outlined,
      title: 'Assistant',
      trailing: picked
          ? IconButton(
              tooltip: 'Use the app default here',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              color: AppPalette.textFaint,
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: () => _useAppDefault(ref),
            )
          : null,
      child: !picked
          ? const RailHint(
              'Following the app default. Pick an assistant or a model in a '
              'chat here and this project keeps it — your other projects keep '
              'theirs.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (agent != null)
                  _Line(
                    leading: AgentMark(tool: agent, size: 16),
                    label: agent.name,
                  ),
                if (agent != null && model != null) const SizedBox(height: 8),
                if (model != null)
                  _Line(
                    leading: Icon(
                      Icons.memory_rounded,
                      size: 15,
                      color: AppPalette.textSecondary,
                    ),
                    label: model,
                    mono: true,
                  ),
              ],
            ),
    );
  }

  /// Put both back on the app's standing choice. One action for the pair: they
  /// are one decision ("what answers me here"), and clearing only half would
  /// leave a project quietly steering chats it looks like it has stopped
  /// steering.
  void _useAppDefault(WidgetRef ref) {
    final projects = ref.read(projectsProvider.notifier);
    projects.setAgent(project.id, null);
    projects.setModel(project.id, null);
  }
}

/// One fact on its own row: a 16px leading slot, then the name.
class _Line extends StatelessWidget {
  const _Line({required this.leading, required this.label, this.mono = false});

  final Widget leading;
  final String label;

  /// Model ids are identifiers, not prose — set in the code face so they're read
  /// as the exact string the grid serves.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(width: 16, child: Center(child: leading)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
              fontFamily: mono ? AppFont.mono : null,
              fontFamilyFallback: mono ? AppFont.monoFallback : null,
            ),
          ),
        ),
      ],
    );
  }
}
