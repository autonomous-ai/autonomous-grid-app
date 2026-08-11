import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Whether this computer takes coding tasks from the grid, and how many at once.
///
/// Off by default, and that is the CLI's own decision rather than this app's:
/// claiming a task runs a coding agent against somebody else's repository on
/// this machine and **pays for it out of the operator's own Claude
/// subscription**. Nothing about opening the app should start spending that.
class TaskServingPrefs {
  const TaskServingPrefs({
    this.enabled = false,
    this.maxTasks = 1,
    this.workspaceRoot,
  });

  /// Claim tasks at all.
  final bool enabled;

  /// How many run at once. The grid's own default is 1; this is the number the
  /// whole team shares, not one each.
  final int maxTasks;

  /// Where task workspaces live. Null leaves the CLI's own default in place —
  /// which is the right thing to send, because writing the default back as an
  /// explicit value would pin this app to a path the CLI is free to change.
  final String? workspaceRoot;

  TaskServingPrefs copyWith({
    bool? enabled,
    int? maxTasks,
    String? workspaceRoot,
  }) => TaskServingPrefs(
    enabled: enabled ?? this.enabled,
    maxTasks: maxTasks ?? this.maxTasks,
    workspaceRoot: workspaceRoot ?? this.workspaceRoot,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'max_tasks': maxTasks,
    if (workspaceRoot != null) 'workspace_root': workspaceRoot,
  };

  static TaskServingPrefs fromJson(Map<String, dynamic> json) {
    final max = json['max_tasks'];
    final root = json['workspace_root'];
    return TaskServingPrefs(
      enabled: json['enabled'] == true,
      // Clamped rather than trusted: the file is editable by hand, and a zero
      // would read to the CLI as "claim nothing" while this app showed the
      // switch as on.
      maxTasks: (max is int && max >= 1) ? max : 1,
      workspaceRoot: (root is String && root.trim().isNotEmpty)
          ? root.trim()
          : null,
    );
  }
}

/// The environment `grid join` needs to make this machine a task provider.
///
/// Pure, and tested, for the reason every argv builder in this app is: the CLI
/// reads these by name, a wrong one is silently ignored, and a machine that
/// quietly never claims a task looks exactly like a grid with no work on it.
///
/// **Empty when serving is off** — not `GRID_TASKS=0`. The variable's absence
/// is what the CLI treats as off, and sending a "no" is one more thing that can
/// be spelled wrong.
///
/// `GRID_TASK_CLAUDE_CONFIG_DIR` is deliberately never set. On macOS the Claude
/// credential lives in the Keychain, and setting that variable — *even to its
/// own default path* — makes Claude Code look for a credentials file that is
/// not there; every task then fails with an empty message and `Not logged in`.
Map<String, String> taskServingEnv(TaskServingPrefs prefs) {
  if (!prefs.enabled) return const {};
  final root = prefs.workspaceRoot;
  return {
    'GRID_TASKS': '1',
    'GRID_MAX_TASKS': '${prefs.maxTasks < 1 ? 1 : prefs.maxTasks}',
    if (root != null && root.isNotEmpty) 'GRID_TASK_ROOT': root,
  };
}

/// Reads and writes `~/.grid/app/task_serving.json`.
///
/// App-owned and lenient like the other stores here: a missing or unreadable
/// file reads as "not serving", which is the safe answer — the failure mode of
/// guessing wrong is spending somebody's subscription without being asked.
class TaskServingStore {
  TaskServingStore({File? file}) : _file = file ?? GridPaths.taskServingFile;

  final File _file;

  TaskServingPrefs load() {
    try {
      if (!_file.existsSync()) return const TaskServingPrefs();
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const TaskServingPrefs();
      return TaskServingPrefs.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      return const TaskServingPrefs();
    }
  }

  void save(TaskServingPrefs prefs) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(prefs.toJson()),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final taskServingStoreProvider = Provider<TaskServingStore>(
  (ref) => TaskServingStore(),
);

/// This computer's task-serving settings. Every change persists.
final taskServingProvider =
    NotifierProvider<TaskServingController, TaskServingPrefs>(
      TaskServingController.new,
    );

class TaskServingController extends Notifier<TaskServingPrefs> {
  @override
  TaskServingPrefs build() => ref.read(taskServingStoreProvider).load();

  /// Turn task serving on or off.
  ///
  /// Takes effect the next time this computer joins the grid: the environment
  /// is read by `grid join`, and the serve loop that claims tasks lives inside
  /// that process. Said out loud on screen rather than implied.
  void setEnabled(bool enabled) => _write(state.copyWith(enabled: enabled));

  void setMaxTasks(int maxTasks) =>
      _write(state.copyWith(maxTasks: maxTasks < 1 ? 1 : maxTasks));

  void setWorkspaceRoot(String? root) => _write(
    TaskServingPrefs(
      enabled: state.enabled,
      maxTasks: state.maxTasks,
      workspaceRoot: (root == null || root.trim().isEmpty) ? null : root.trim(),
    ),
  );

  void _write(TaskServingPrefs prefs) {
    state = prefs;
    ref.read(taskServingStoreProvider).save(prefs);
  }
}
