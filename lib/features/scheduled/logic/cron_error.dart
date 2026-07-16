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
  if (_isModelDriftSkip(text)) {
    return const CronRunError(
      summary:
          'Paused to avoid an unexpected charge — the model your assistant '
          'uses has changed since this task was created, so it was not run.',
      hint:
          'Delete this task and create it again to run it on the '
          'current model.',
    );
  }
  return CronRunError(summary: text);
}

/// Hermes skips (and never bills) an unpinned job when the global model or
/// provider has drifted from what it was at creation — a fail-closed guard
/// against surprise spend. Match on the guard's stable phrasing rather than the
/// exact model names, which differ for every grid.
bool _isModelDriftSkip(String text) {
  final lower = text.toLowerCase();
  return lower.contains('unintended spend') ||
      (lower.contains('unpinned') && lower.contains('drift'));
}
