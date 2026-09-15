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
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chats.dart';
import 'chat_list_screen.dart';
import 'parts.dart';

/// The project list.
class ProjectsSection extends ConsumerWidget {
  const ProjectsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
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
          const SectionLabel('Projects'),
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
    AppTheme.watch(context);
    return GridListRow(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatListScreen(
            projectId: project.id,
            title: project.name.isEmpty ? 'Project' : project.name,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 16, color: AppPalette.textFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.name.isEmpty ? 'Untitled project' : project.name,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                RowDetail([project.agent, project.model]),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppPalette.textFaint,
          ),
        ],
      ),
    );
  }
}
