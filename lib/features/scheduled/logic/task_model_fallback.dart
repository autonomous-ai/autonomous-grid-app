import '../../network/logic/node_display.dart';
import 'cron_error.dart';
import 'scheduled_job.dart';

/// The tasks whose pinned model has stopped working, and should fall back to the
/// grid's router (`auto`) so tomorrow's run still produces something.
///
/// A pinned model is the user's choice and isn't second-guessed while it works.
/// Two things end that, and both leave the task silently dead otherwise — it
/// fires at 8am with nobody watching:
///
///  - the grid no longer serves that id (the machine serving it went off, the
///    seat was removed);
///  - the last run failed for a reason that blames the model
///    ([isModelRunFailure]), not the task.
///
/// [served] is what the grid lists right now. **Empty means "not loaded"**, never
/// "serves nothing": reading a missing model list as "every model is gone" would
/// re-point every task on it at the first sweep after launch.
///
/// Pure, so the rule that rewrites somebody's saved task is unit-tested rather
/// than only observed in a sweep.
List<String> autoFallbackTargets(List<ScheduledJob> jobs, Set<String> served) =>
    List.unmodifiable([
      for (final job in jobs)
        if (_needsFallback(job, served)) job.id,
    ]);

bool _needsFallback(ScheduledJob job, Set<String> served) {
  final model = job.model?.trim();
  // Unpinned follows the computer's model already, and one already on the router
  // has nowhere further to fall.
  if (model == null || model.isEmpty || model == kAutoModelId) return false;
  final gone = served.isNotEmpty && !served.contains(model);
  final blamed = job.lastError != null && isModelRunFailure(job.lastError!);
  return gone || blamed;
}

/// Why a task's model was swapped, for the log — the app rewrote something the
/// user chose, so it says which task, from what, and on whose evidence.
String autoFallbackReason(ScheduledJob job, Set<String> served) {
  final model = job.model ?? '';
  if (served.isNotEmpty && !served.contains(model)) {
    return '"${job.name}": this grid no longer serves $model';
  }
  return '"${job.name}": $model failed its last run — ${job.lastError}';
}
