/// The projects on the computer.
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

/// Every project, and the way to start one.
class ProjectsTab extends ConsumerWidget {
  const ProjectsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final projects = ref.watch(projectsProvider);
    return projects.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _Problem(
        message: '$error',
        onRetry: () => ref.invalidate(projectsProvider),
      ),
      data: (rows) => rows.isEmpty
          ? const _NoProjects()
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              children: [
                for (final project in rows.values) _ProjectTile(project),
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

class _NoProjects extends StatelessWidget {
  const _NoProjects();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No projects yet. Start one and your computer makes the folder for '
          'it.',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
