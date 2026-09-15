/// The projects on the computer, shown on the connected screen.
///
/// A project is where a chat's work happens — its folder, its model, its agent
/// — so listing them is how somebody finds the conversation they want without
/// reading 158 titles. Tapping one narrows the chat list to it rather than
/// opening a screen of its own: the rows are the same rows, and two screens
/// showing the same conversation are two places for it to drift.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_chats.dart';
import 'chat_list_screen.dart';

/// The project list.
class ProjectsSection extends ConsumerWidget {
  const ProjectsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projects = ref.watch(projectsProvider);
    // Nothing at all rather than an empty heading: a computer with no projects
    // is a normal computer, and a "Projects" title over blank space reads as
    // something that failed to load.
    final rows = projects.value?.values.toList() ?? const <ProjectRow>[];
    if (rows.isEmpty) return const SizedBox.shrink();
    // Owns the gap above it, because it is allowed to disappear entirely: a
    // spacer left behind by the caller would open a hole on every computer that
    // has no projects.
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Projects', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final project in rows) _ProjectTile(project),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile(this.project);

  final ProjectRow project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = [
      if (project.agent.isNotEmpty) project.agent,
      if (project.model.isNotEmpty) project.model,
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatListScreen(
            projectId: project.id,
            title: project.name.isEmpty ? 'Project' : project.name,
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    project.name.isEmpty ? 'Untitled project' : project.name,
                    style: theme.textTheme.bodyLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.textTheme.bodySmall?.color,
            ),
          ],
        ),
      ),
    );
  }
}
