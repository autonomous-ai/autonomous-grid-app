import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/section_scaffold.dart';
import '../../logic/code_project.dart';
import '../../logic/code_projects_controller.dart';
import '../../logic/project_status.dart';
import '../../logic/project_status_controller.dart';
import 'import_repo_dialog.dart';
import 'members_card.dart';
import 'project_actions_bar.dart';
import 'project_status_card.dart';

/// The open project with no task open: where it stands, what to do about it,
/// and who is in it.
class ProjectOverview extends ConsumerWidget {
  const ProjectOverview({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref
        .watch(codeProjectsProvider)
        .asData
        ?.value
        .where((candidate) => candidate.id == projectId)
        .firstOrNull;
    final status = ref.watch(projectStatusProvider(projectId));

    return SectionScaffold(
      title: project?.name ?? 'Project',
      subtitle:
          'A repository the grid hosts. Tasks run against it on other '
          'people’s computers, and land on your own copy.',
      child: switch (status) {
        AsyncData(:final value) when value.needsImport => _NeedsImport(
          projectId: projectId,
        ),
        AsyncData(:final value) => _Body(status: value, project: project),
        AsyncError(:final error) => ErrorBox(message: '$error'),
        _ => const LoadingView(),
      },
    );
  }
}

/// The project exists but has no code in it. Nothing else here can work until
/// somebody imports a repository, so nothing else is offered.
class _NeedsImport extends StatelessWidget {
  const _NeedsImport({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.folderGit2300,
    title: 'No code in this project yet',
    message:
        'Bring in an existing repository, with its history. That is the only '
        'way a project gets its code, and no task can run until it has some.',
    action: FilledButton(
      onPressed: () => showImportRepoDialog(context, projectId: projectId),
      child: const Text('Bring in a repository'),
    ),
  );
}

/// The working overview.
class _Body extends StatelessWidget {
  const _Body({required this.status, required this.project});

  final ProjectStatus status;
  final GridProject? project;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ProjectStatusCard(status: status),
        const SizedBox(height: 20),
        ProjectActionsBar(status: status),
        const SizedBox(height: 24),
        MembersCard(
          projectId: status.projectId,
          // Admitting people is the owner's call, so the button only appears
          // where pressing it would work.
          canInvite: project?.isOwner ?? false,
        ),
      ],
    );
  }
}
