import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/widgets/rail_section_header.dart';
import '../../../shared/layouts/widgets/sidebar_item.dart';
import '../logic/code_project.dart';
import '../logic/code_projects_controller.dart';
import 'widgets/new_project_dialog.dart';
import 'widgets/rail_note.dart';

/// The sidebar in Code mode: the one thing you do, and the repositories you
/// share with your team.
///
/// It mirrors the Home rail deliberately — an action on top, one group under it
/// — so switching halves changes what the rows *are* and never how the rail
/// works. The tasks a project has run are not in here: they are the project's
/// conversation, and they live in it.
class CodeRail extends ConsumerWidget {
  const CodeRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(codeProjectsProvider);
    final openId = ref.watch(selectedCodeProjectProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: SidebarItem(
            icon: LucideIcons.folderPlus300,
            label: 'New project',
            emphasized: true,
            onTap: () => showNewProjectDialog(context),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              const RailSectionHeader(label: 'Projects'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: switch (projects) {
                  AsyncData(:final value) => _ProjectRows(
                    projects: value,
                    openId: openId,
                  ),
                  AsyncError(:final error) => RailNote(
                    _shortFailure(error),
                    onRetry: () => ref.invalidate(codeProjectsProvider),
                  ),
                  _ => const RailNote('Loading your projects…'),
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The first line of a failure, for a rail 284px wide.
///
/// The grid's own refusals are written for a terminal and run to two or three
/// sentences; the rail has room for one, and the pane beside it shows the whole
/// thing. Cutting mid-sentence is worse than cutting at one, so this stops at
/// the first full stop it can.
String _shortFailure(Object error) {
  final text = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
  final stop = text.indexOf('. ');
  return stop == -1 ? text : text.substring(0, stop + 1);
}

/// Every project on this grid, the open one highlighted.
class _ProjectRows extends ConsumerWidget {
  const _ProjectRows({required this.projects, required this.openId});

  final List<GridProject> projects;
  final String? openId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (projects.isEmpty) {
      return const RailNote(
        'No shared projects yet. Start one with + above, then bring a '
        'repository into it.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final project in projects)
          SidebarItem(
            icon: LucideIcons.folderGit2300,
            label: project.name,
            selected: project.id == openId,
            onTap: () => ref
                .read(selectedCodeProjectProvider.notifier)
                .select(project.id),
          ),
      ],
    );
  }
}
