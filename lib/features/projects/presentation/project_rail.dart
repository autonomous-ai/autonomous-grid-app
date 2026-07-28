import 'package:flutter/material.dart';

import '../logic/project.dart';
import 'widgets/project_context_card.dart';
import 'widgets/project_instructions_card.dart';
import 'widgets/project_memory_card.dart';
import 'widgets/project_scheduled_card.dart';

/// The right rail for the selected project — Cowork-style cards that gather what
/// governs the assistant in this folder: its rules, its context, its scheduled
/// tasks, and what it should remember.
///
/// Scrolls on its own so a long memory or task list never pushes the list beside
/// it or overflows a short window. The stateful cards are keyed by project id so
/// switching selection starts them fresh, never carrying another project's
/// half-typed note across.
class ProjectRail extends StatelessWidget {
  const ProjectRail({required this.project, super.key});

  final Project project;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ProjectInstructionsCard(
          key: ValueKey('rules-${project.id}'),
          project: project,
        ),
        const SizedBox(height: 12),
        ProjectContextCard(project: project),
        const SizedBox(height: 12),
        ProjectScheduledCard(project: project),
        const SizedBox(height: 12),
        ProjectMemoryCard(
          key: ValueKey('memory-${project.id}'),
          project: project,
        ),
      ],
    );
  }
}
