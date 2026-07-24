/// The answer a scheduled run produced, lifted out of Hermes's boilerplate.
///
/// Every run's `.md` opens with a metadata block — the job name, its id, the run
/// time, the raw cron schedule (`0 8 * * 1-5`) — then `## Prompt` echoing the
/// prompt, and only then `## Response` with the actual answer (`## Error` when it
/// failed). None of the header means anything to the person reading the digest,
/// and a preview eight lines tall was filling all eight with it — so this returns
/// just what's under the answer heading.
///
/// Falls back to the whole text when the output doesn't follow the template — a
/// script job writes its stdout straight after the metadata with no heading — so
/// an unexpected shape shows everything rather than hiding it behind a guess.
String cronOutputBody(String raw) {
  final match = _answerHeading.firstMatch(raw);
  return (match == null ? raw : raw.substring(match.end)).trim();
}

/// The heading that introduces the answer, whichever word Hermes used for it
/// (`## Response` for a normal run, `## Error` for a failed one). Anchored to a
/// whole line so a `## Response` written *inside* an answer can't be mistaken for
/// the section divider.
final _answerHeading = RegExp(
  r'^##[ \t]+(Response|Result|Output|Answer|Error)[ \t]*$',
  multiLine: true,
  caseSensitive: false,
);
