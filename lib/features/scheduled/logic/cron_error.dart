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
  if (isCronIdleTimeout(text)) {
    return const CronRunError(
      summary:
          'This run was stopped: the AI went quiet part-way through, and no '
          'answer came back for as long as a task is allowed to wait. The task '
          'will try again at its next run.',
      hint:
          'If it keeps happening, ask for less in one go — fewer items, a '
          'shorter answer — or run it on one named model instead of Auto.',
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

/// Hermes's scheduler stops a run that has shown no sign of life — no tool call,
/// no API response — for its idle limit, and records a `TimeoutError` naming how
/// long it waited. It is not a stuck task: a scheduled run answers in **one
/// non-streaming call**, so nothing touches that clock while a long report is
/// being written, and the limit is reached by the answer itself.
///
/// A one-off, so it stays out of [isBlockingCronError]: the next run may well
/// finish. The app raises the limit this trips over (`HERMES_CRON_TIMEOUT`, see
/// `hermes_cron_watchdog.dart`); the wording here is what the user reads when it
/// trips anyway.
///
/// Matched on the stable half of the sentence — the seconds and the job name
/// differ every time.
bool isCronIdleTimeout(String text) {
  final lower = text.toLowerCase();
  return lower.contains('idle for') &&
      (lower.contains('timeouterror') || lower.contains('cron job'));
}

/// Whether a failed run blames the **model** the task is pinned to, rather than
/// the task itself.
///
/// These are the failures another model would survive: nothing on the grid
/// serving that id any more (the machine went off, the seat was removed), or the
/// relay refusing to route it. A prompt that crashed a tool is not one of them —
/// swapping the model there would hide a bug behind a model change.
///
/// Matched on the stable half of each phrase, since the relay and Hermes each
/// word theirs differently and both carry the model id in the middle.
bool isModelRunFailure(String text) {
  final lower = text.toLowerCase();
  return lower.contains('no providers available') ||
      lower.contains('model not found') ||
      lower.contains('unknown model') ||
      lower.contains('is not serving') ||
      lower.contains('no machine on this grid is serving') ||
      isNoModelConfigured(lower);
}

/// Cron failures that keep failing until the user acts — they get the blunter
/// "Won't run" status, not the hopeful "Last run failed". One predicate so the
/// status layer and any future caller can't disagree about which errors those
/// are.
bool isBlockingCronError(String text) =>
    isModelDriftSkip(text) || isNoModelConfigured(text);
