/// A scheduler run failure, translated for a person to read.
///
/// Hermes reports a failed run as a raw engineering string — a `RuntimeError`,
/// a provider stack-trace line, an internal issue reference. This turns the
/// failures we recognize into a plain summary and a concrete next step; anything
/// unrecognized falls through as its original text, so an unknown error still
/// tells the user what Hermes said instead of being swallowed.
class CronRunError {
  const CronRunError({required this.summary, this.hint});

  /// One plain-language line naming what went wrong.
  final String summary;

  /// What the user can do about it, or null when there's nothing specific to
  /// suggest (an unrecognized error is shown verbatim, with no invented advice).
  final String? hint;
}

/// Translate Hermes's raw last-run error into something a person can act on.
///
/// Pure and side-effect free so it can be unit-tested and reused by both the
/// task detail's "Last error" row and the "Run now" feedback.
CronRunError describeCronRunError(String raw) {
  final text = raw.trim();
  if (isModelDriftSkip(text)) {
    return const CronRunError(
      summary:
          'Paused to avoid an unexpected charge — the model your assistant '
          'uses has changed since this task was created, so it was not run.',
      hint:
          'Choose "Use the current model" above to run it on the model this '
          'computer uses now.',
    );
  }
  if (isNoModelConfigured(text)) {
    return const CronRunError(
      summary:
          'This computer has no AI model set for your tasks yet, so this one '
          "couldn't run.",
      hint:
          'Delete this task and create it again — the app sets up a model for '
          'it when you do (pick a grid in Chat first if you have not).',
    );
  }
  return CronRunError(summary: text);
}

/// Hermes skips (and never bills) an unpinned job when the global model or
/// provider has drifted from what it was at creation — a fail-closed guard
/// against surprise spend. Match on the guard's stable phrasing rather than the
/// exact model names, which differ for every grid.
///
/// This isn't a run that failed and might pass next time: until the user acts,
/// every future run is skipped the same way. The status layer treats it as a
/// task that won't run, not one that's merely "running with a failed last run".
bool isModelDriftSkip(String text) {
  final lower = text.toLowerCase();
  return lower.contains('unintended spend') ||
      (lower.contains('unpinned') && lower.contains('drift'));
}

/// Hermes ran the job but had no model to answer with — nothing pinned on the
/// job, no `HERMES_MODEL`, and `config.yaml`'s `model.default` missing or empty.
/// This is the app's own gap when a task was created before Hermes was ever
/// pointed at a grid (`HermesGridLink.ensureModelForSelectedGrid` now closes it
/// at creation).
///
/// Like the drift skip, it won't clear on its own: every future run fails the
/// same way until a model is set, so the status layer treats it as a task that
/// won't run rather than one with a merely unlucky last run. Matched on the
/// stable wording, not the exact env/config detail Hermes prints alongside it.
bool isNoModelConfigured(String text) {
  final lower = text.toLowerCase();
  return lower.contains('no model configured') ||
      lower.contains('model.default missing or empty');
}

/// Cron failures that keep failing until the user acts — they get the blunter
/// "Won't run" status, not the hopeful "Last run failed". One predicate so the
/// status layer and any future caller can't disagree about which errors those
/// are.
bool isBlockingCronError(String text) =>
    isModelDriftSkip(text) || isNoModelConfigured(text);
