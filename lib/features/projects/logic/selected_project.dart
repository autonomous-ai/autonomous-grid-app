import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'project.dart';

/// Which project the Projects rail is showing, or null before one is picked.
///
/// The list on the left is the source of truth for *what* exists; this is only
/// which row the right rail is dressed for. [resolvedSelectedProjectProvider]
/// falls back to the first project so the rail is never blank while projects
/// exist, and heals a selection whose project was removed.
final selectedProjectIdProvider = NotifierProvider<SelectedProjectId, String?>(
  SelectedProjectId.new,
);

class SelectedProjectId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

/// The project the rail should show: the picked one when it's still in the list,
/// otherwise the first project (so opening the screen lands on something), or
/// null when there are no projects at all.
final resolvedSelectedProjectProvider = Provider<Project?>((ref) {
  final projects = ref.watch(sortedProjectsProvider);
  if (projects.isEmpty) return null;
  final picked = ref.watch(selectedProjectIdProvider);
  return projects.where((p) => p.id == picked).firstOrNull ?? projects.first;
});
