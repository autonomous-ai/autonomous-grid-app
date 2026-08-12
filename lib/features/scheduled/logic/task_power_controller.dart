import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_task_policy.dart';
import '../../agents/logic/adapters/hermes_tool.dart';
import '../../../shared/copy/setup_hints.dart';

/// The seam onto Hermes's own scheduler settings, or null when there's no agent
/// on this computer to schedule anything on.
final hermesTaskPolicyProvider = Provider<HermesTaskPolicy?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesTaskPolicy();
});

/// What scheduled tasks may do to this computer, read from Hermes's own config so
/// the screen can never claim a limit that isn't really there.
///
/// A task runs unattended: there is nobody to ask, so the answer is decided in
/// advance and the screen says which one it is.
final taskPowerProvider = AsyncNotifierProvider<TaskPowerController, TaskPower>(
  TaskPowerController.new,
);

class TaskPowerController extends AsyncNotifier<TaskPower> {
  @override
  Future<TaskPower> build() async {
    final policy = ref.read(hermesTaskPolicyProvider);
    if (policy == null) return TaskPower.fullAccess;
    return policy.read();
  }

  /// Change what tasks may do. Returns null on success, else a line for the user.
  Future<String?> set(TaskPower power) async {
    final policy = ref.read(hermesTaskPolicyProvider);
    if (policy == null) return _noAgent;
    try {
      await policy.write(power);
    } on Object catch (error) {
      return "Couldn't change what tasks are allowed to do: $error";
    }
    state = AsyncData(power);
    return null;
  }

  /// Write the current choice into Hermes's config before a task is saved, so
  /// what the screen says a task may do is what it will actually be allowed to
  /// do — including on a machine whose config has never mentioned it.
  Future<void> applyBeforeSaving() async {
    final policy = ref.read(hermesTaskPolicyProvider);
    if (policy == null) return;
    try {
      await policy.write(await future);
    } on Object {
      // A config we can't write is the setting's problem to report, not a reason
      // to refuse to save the task.
      return;
    }
  }

  static final _noAgent = notSetUpToMessage('run tasks');
}
