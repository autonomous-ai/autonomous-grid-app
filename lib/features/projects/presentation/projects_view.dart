import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/toast.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../logic/project.dart';
import 'add_project.dart';
import 'project_instructions_dialog.dart';
import 'project_menu.dart';

/// The Projects screen: the folders on this computer the assistant may read.
///
/// A chat opened inside a project can answer about the files in it — nothing is
/// copied or uploaded, the agent simply runs with that folder open. This screen
/// is where projects are added, opened in Finder, and forgotten again.
class ProjectsView extends ConsumerWidget {
  const ProjectsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(sortedProjectsProvider);

    return SectionScaffold(
      title: 'Projects',
      subtitle:
          'Folders the assistant may read while it answers you. Open a chat '
          "inside one and you can ask about its files — it looks, it doesn't "
          'change them.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => addProjectFromPicker(ref),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Add a project'),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: projects.isEmpty
                ? const _Empty()
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: projects.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) =>
                        _ProjectCard(project: projects[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One project: where it is, how many chats live in it, and what you can do —
/// start a chat in it, open the folder, or forget it.
class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Counts live chats only, so the number here matches the rows the sidebar
    // actually shows under this project.
    final chats = ref
        .watch(chatSessionsProvider)
        .live
        .where((c) => c.projectId == project.id)
        .length;
    final missing = !project.exists;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            missing ? Icons.folder_off_outlined : Icons.folder_rounded,
            size: 20,
            color: missing ? theme.colorScheme.error : AppPalette.textSecondary,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  project.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textFaint,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  missing
                      ? "This folder isn't there any more."
                      : _chatsLabel(chats),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: missing
                        ? theme.colorScheme.error
                        : AppPalette.textSecondary,
                  ),
                ),
                if (!missing && project.instructions.trim().isNotEmpty)
                  const _RulesBadge(),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _Actions(project: project, missing: missing),
        ],
      ),
    );
  }

  static String _chatsLabel(int chats) => switch (chats) {
    0 => 'No chats in it yet',
    1 => '1 chat',
    _ => '$chats chats',
  };
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.project, required this.missing});

  final Project project;
  final bool missing;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final opened = await ref
        .read(hostShellServiceProvider)
        .openFolder(project.path);
    if (!context.mounted || opened) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: "Couldn't open ${project.path}",
        severity: ToastSeverity.error,
      ),
    );
  }

  void _newChat(WidgetRef ref) {
    ref.read(chatSessionsProvider.notifier).newChat(projectId: project.id);
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    if (await confirmRemoveProject(context, project)) {
      ref.read(projectsProvider.notifier).remove(project.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRules = project.instructions.trim().isNotEmpty;
    return Wrap(
      spacing: 6,
      children: [
        if (!missing)
          IconButton(
            tooltip: 'New chat in this project',
            iconSize: 18,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => _newChat(ref),
          ),
        if (!missing)
          IconButton(
            tooltip: hasRules ? 'Edit agent rules' : 'Add agent rules',
            iconSize: 18,
            color: hasRules ? AppPalette.accent : AppPalette.textSecondary,
            icon: const Icon(Icons.rule_rounded),
            onPressed: () => showProjectInstructionsDialog(context, project),
          ),
        if (!missing)
          IconButton(
            tooltip: 'Open folder',
            iconSize: 18,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.drive_folder_upload_outlined),
            onPressed: () => _open(context, ref),
          ),
        IconButton(
          tooltip: 'Remove from Grid',
          iconSize: 18,
          color: AppPalette.textSecondary,
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => _forget(context, ref),
        ),
      ],
    );
  }
}

/// Marks a project that carries standing rules for the agent, so it's obvious
/// at a glance which folders steer the assistant.
class _RulesBadge extends StatelessWidget {
  const _RulesBadge();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.rule_rounded, size: 13, color: AppPalette.accent),
          const SizedBox(width: 5),
          Text(
            'Agent rules set',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppPalette.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// No projects yet — say what one is for, and offer the single action.
class _Empty extends ConsumerWidget {
  const _Empty();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 34,
              color: AppPalette.textFaint,
            ),
            const SizedBox(height: 14),
            Text(
              'No projects yet.',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Add a folder — a codebase, a pile of notes, a set of documents — '
              'and every chat you open inside it can answer about those files.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => addProjectFromPicker(ref),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Add a project'),
            ),
          ],
        ),
      ),
    );
  }
}
