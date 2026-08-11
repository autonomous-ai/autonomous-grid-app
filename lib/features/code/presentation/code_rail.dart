import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/widgets/rail_section_header.dart';
import '../../../shared/layouts/widgets/sidebar_item.dart';
import '../logic/code_project.dart';
import '../logic/code_projects_controller.dart';
import '../logic/project_status_controller.dart';
import 'widgets/code_task_rows.dart';
import 'widgets/new_project_dialog.dart';
import 'widgets/new_task_dialog.dart';
import 'widgets/rail_note.dart';

/// The sidebar in Code mode: the one thing you do, the repositories you share
/// with your team, and what has been run against the open one.
///
/// It mirrors the Home rail deliberately — an action on top, groups under it —
/// so switching halves changes what the rows *are* and never how the rail
/// works.
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
          child: _PrimaryAction(projectId: openId),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              RailSectionHeader(
                label: 'Projects',
                onAdd: () => showNewProjectDialog(context),
                addTooltip: 'Start a new shared project',
              ),
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
              if (openId != null) CodeTaskRows(projectId: openId),
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

/// The rail's primary action, which always does something.
///
/// It changes with what is open rather than greying out: with no project there
/// is no task to create, and an accent-washed row that reads as the screen's
/// main action while refusing every click is the worst of both. The one case
/// that *is* disabled is a task slot already held — there the grid's rule is
/// the reason, and the tooltip gives it.
class _PrimaryAction extends ConsumerWidget {
  const _PrimaryAction({required this.projectId});

  final String? projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = projectId;
    if (id == null) {
      return SidebarItem(
        icon: LucideIcons.folderPlus300,
        label: 'New project',
        emphasized: true,
        onTap: () => showNewProjectDialog(context),
      );
    }
    final holder = ref
        .watch(projectStatusProvider(id))
        .asData
        ?.value
        .slotHolder;
    return SidebarItem(
      icon: LucideIcons.squarePen300,
      label: 'New task',
      emphasized: true,
      enabled: holder == null,
      tooltip: holder == null
          ? null
          : 'A task of yours is still going here. One at a time in a project — '
                'open it to watch or stop it.',
      onTap: () => showNewTaskDialog(context, projectId: id),
    );
  }
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
