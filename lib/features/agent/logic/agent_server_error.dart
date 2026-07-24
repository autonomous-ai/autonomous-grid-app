import 'dart:convert';

/// A turn that ended with nothing to show. Shared by both agents so a silent
/// Hermes and a silent Codex read the same to the user.
const String kAgentNoAnswer = "The agent didn't return an answer.";

/// A plain line for why the assistant on *this computer* wouldn't start, from
/// the raw reason it left on stderr as it died.
///
/// The user runs Grid, not a terminal. Hermes's own words — "ACP dependencies
/// not installed. Install them with: pip install -e '.[acp]'" — name a fix they
/// can't carry out and a tool they've never opened, so quoting it verbatim (as
/// the chat did) is worse than useless: it reads as a wall of jargon with a
/// dead-end instruction. Grid installs and repairs the assistant itself, from
/// the Agents screen, so every case points there instead — and a reason we
/// don't recognise stays a calm "wouldn't start" rather than dumping a Python
/// traceback into the conversation. Retryable failures never reach here; they
/// keep their own "try again". The raw reason is logged separately (§6), so
/// humanizing it here is never the only record.
String friendlyAgentStartupError(String raw) {
  final said = raw.toLowerCase();
  // A half-finished install: the binary is there but a piece it needs isn't.
  final incomplete =
      (said.contains('acp') || said.contains('dependenc')) &&
          (said.contains('not installed') || said.contains('pip install')) ||
      said.contains('no module named') ||
      said.contains('modulenotfound');
  if (incomplete) {
    // Deliberately does **not** promise that reinstalling fixes it. This case is
    // usually not a broken install at all: the installer fetches Hermes without
    // the piece the chat talks to it through, so a fresh install lands in
    // exactly this state and Update runs the same command again. Saying "reinstall
    // it, then try again" sent users round a loop that could not end — the same
    // trap as shipping "Hermes works here" while Hermes was failing (§5). Offer
    // the button, name its limit, and point at the way out that exists.
    return "Part of the assistant's setup is missing on this computer. Update "
        "it on the Agents screen — if that doesn't help, this needs a newer "
        'version of Grid.';
  }
  return "The assistant on this computer wouldn't start. Update it on the "
      'Agents screen, then try again.';
}

/// The grid's own refusal, as Hermes hands it over: the assistant's whole answer
/// is the failed HTTP call, verbatim — `HTTP 400: {"detail":"No active provider
/// for this model supports tools"}`.
///
/// Left alone it lands in the chat as if the assistant had said it, so the user
/// reads a status code and a JSON envelope where an answer should be. Returns a
/// plain line with a next step for a reply that is really an error, or null for
/// a genuine answer — the caller keeps the raw text for the log either way.
String? friendlyAgentServerError(String reply) {
  final match = _envelope.firstMatch(reply.trim());
  if (match == null) return null;
  final status = int.parse(match.group(1)!);
  final detail = _detailOf(match.group(2)!).toLowerCase();

  if (detail.contains('supports tools')) {
    return "This grid's AI can't use tools, and the assistant needs them to "
        'answer. Pick another model, or share one from this computer.';
  }
  if (detail.contains('no providers') ||
      detail.contains('no active provider')) {
    return "Nobody on this grid is running that model right now. Pick another "
        'model, or share one from this computer.';
  }
  if (status == 401 || status == 403) {
    return "This grid turned the assistant away. Sign out and back in, then "
        'try again.';
  }
  return 'The grid couldn\'t answer the assistant (error $status). Try again, '
      'or pick another model.';
}

/// `HTTP <status>: <body>` and nothing else — the whole reply, so an answer that
/// merely *discusses* a status code is never mistaken for a failed one.
final _envelope = RegExp(r'^HTTP (\d{3}):\s*(.*)$', dotAll: true);

/// The `detail` a grid error carries, or the body as-is when it isn't the JSON
/// envelope the relay normally sends.
String _detailOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['detail'] is String) {
      return decoded['detail'] as String;
    }
  } on FormatException {
    return body;
  }
  return body;
}
