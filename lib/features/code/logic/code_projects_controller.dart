import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import 'code_argv.dart';
import 'code_cli.dart';
import 'code_errors.dart';
import 'code_project.dart';
import 'code_write_results.dart';

/// The grid this feature is acting on, or null when the user has no grid
/// selected. Every command carries it, so a grid switch moves the whole screen
/// rather than leaving one pane pointing at the old one.
final codeGridIdProvider = Provider<String?>(
  (ref) => ref.watch(selectedNetworkProvider)?.networkId,
);

/// The grid these commands act on, or a clean refusal. Read rather than
/// watched: an action fires once, and a grid switch mid-action would move the
/// target under a command already in flight.
String requireCodeGrid(Ref ref) {
  final grid = ref.read(codeGridIdProvider);
  if (grid == null) {
    throw const CodeGridException(
      'Pick a grid first — shared projects belong to one.',
    );
  }
  return grid;
}

/// Every shared project this account is a member of, on the selected grid.
final codeProjectsProvider =
    AsyncNotifierProvider<CodeProjectsController, List<GridProject>>(
      CodeProjectsController.new,
      retry: neverRetryCodeCommand,
    );

class CodeProjectsController extends AsyncNotifier<List<GridProject>> {
  @override
  Future<List<GridProject>> build() async {
    final grid = ref.watch(codeGridIdProvider);
    if (grid == null) {
      throw const CodeGridException(
        'Pick a grid first — shared projects belong to one.',
      );
    }
    return _list(grid);
  }

  Future<List<GridProject>> _list(String grid) async {
    final json = await requireCodeCli(ref).object(projectListArgs(grid: grid));
    return GridProject.listFromJson(json);
  }

  /// Create a project, or get the one that already has this name.
  ///
  /// Create-or-get rather than refuse-if-exists, matching the relay: a name is
  /// unique per owner, so running this twice hands back the same project
  /// instead of punishing the second try.
  ///
  /// A new project has **no trunk** — importing a repository is the only way it
  /// gets one, and no task can run until it does.
  Future<GridProject> create(String name) async {
    final json = await requireCodeCli(
      ref,
    ).object(projectCreateArgs(name: name, grid: requireCodeGrid(ref)));
    final project = GridProject.fromJson(json);
    if (project == null) {
      throw const CodeGridException(
        'The grid accepted the project but did not say what its id is, so '
        'nothing can be run in it yet. Try creating it again.',
      );
    }
    await refresh();
    return project;
  }

  /// Import a local repository, with its history, into a project that has no
  /// trunk yet.
  ///
  /// Slow on a big repository: the relay reads every tree the history reaches
  /// before it will let it become the trunk. A refusal leaves the project with
  /// **no trunk on purpose** — half a trunk would be worse — so the fix is to
  /// address what it names and import again.
  Future<ImportResult> importRepository({
    required String projectId,
    required String path,
    String branch = 'HEAD',
  }) async {
    final json = await requireCodeCli(ref).object(
      projectImportArgs(
        path: path,
        projectId: projectId,
        grid: requireCodeGrid(ref),
        branch: branch,
      ),
      timeout: kImportTimeout,
    );
    final result = ImportResult.fromJson(json);
    if (result == null) {
      throw const CodeGridException(
        'The grid did not confirm the repository was imported, so this project '
        'still has no code in it. Try the import again.',
      );
    }
    return result;
  }

  /// Re-read the list from the grid.
  Future<void> refresh() async {
    final grid = ref.read(codeGridIdProvider);
    if (grid == null) return;
    state = await AsyncValue.guard(() => _list(grid));
  }
}

/// Which project the Code screen has open. Null until one is picked; cleared
/// when the selected grid changes, because a project id belongs to one grid.
final selectedCodeProjectProvider =
    NotifierProvider<SelectedCodeProject, String?>(SelectedCodeProject.new);

class SelectedCodeProject extends Notifier<String?> {
  @override
  String? build() {
    // Watched, not read: switching grids rebuilds this and drops a selection
    // that would otherwise address a project the new grid has never heard of.
    ref.watch(codeGridIdProvider);
    return null;
  }

  void select(String? projectId) => state = projectId;
}
