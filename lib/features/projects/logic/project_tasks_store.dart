import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// Remembers which scheduled task belongs to which project — a `{jobId:
/// projectId}` map the app keeps because Hermes's scheduler doesn't know about
/// projects.
///
/// Persisted as `~/.grid/app/project_tasks.json`. App-owned and lenient like the
/// other app stores: a missing or corrupt file reads as no associations rather
/// than throwing, so a stray write never blanks a project's task list.
class ProjectTasksStore {
  ProjectTasksStore({File? file}) : _file = file ?? GridPaths.projectTasksFile;

  final File _file;

  Map<String, String> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on Object {
      return const {};
    }
  }

  void save(Map<String, String> links) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(links),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final projectTasksStoreProvider = Provider<ProjectTasksStore>(
  (ref) => ProjectTasksStore(),
);

/// The task→project links, loaded once on start; every change persists. Keyed by
/// the scheduler's job id, valued by the project the task was created for.
final projectTasksProvider =
    NotifierProvider<ProjectTasksController, Map<String, String>>(
      ProjectTasksController.new,
    );

class ProjectTasksController extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => ref.read(projectTasksStoreProvider).load();

  /// Tie the task [jobId] to [projectId], so it shows under that project's rail.
  void assign(String jobId, String projectId) =>
      _commit({...state, jobId: projectId});

  /// Drop the link for [jobId] — called when a task is removed, so the map
  /// doesn't keep a pointer to a job that no longer exists.
  void unassign(String jobId) {
    if (!state.containsKey(jobId)) return;
    _commit({...state}..remove(jobId));
  }

  void _commit(Map<String, String> next) {
    state = Map.unmodifiable(next);
    ref.read(projectTasksStoreProvider).save(next);
  }
}

/// The ids of the tasks that belong to [projectId] — what a project's Scheduled
/// card filters the scheduler's jobs down to.
final projectJobIdsProvider = Provider.family<Set<String>, String>((
  ref,
  projectId,
) {
  final links = ref.watch(projectTasksProvider);
  return {
    for (final entry in links.entries)
      if (entry.value == projectId) entry.key,
  };
});
