import 'dart:convert';

import '../../../infrastructure/cli/hermes_acp_setup.dart';

/// A turn that ended with nothing to show. Shared by both agents so a silent
/// Hermes and a silent Codex read the same to the user.
const String kAgentNoAnswer = "The agent didn't return an answer.";

/// A turn that laid out a plan and then stopped before finishing it — no steps
/// ticked off, nothing built. Shared by both agents so a stalled Hermes and a
/// stalled Codex read the same. The chat pairs it with the switch-agent button,
/// so "let another agent take this chat" is an offer to try, not a promise (§5).
const String kAgentStalledPlan =
    'The agent planned the work but stopped before finishing it. Try sending '
    'again, or let another agent take this chat.';

/// A turn stopped because the assistant kept redoing the same step — the same
/// file written, or the same command run, over and over — without finishing.
/// [target] names what it was stuck on (a file's base name, or a clipped
/// command) so the line says what happened, and points at the lever that helps:
/// a stronger model. The raw repeats stay in the log to diagnose from (§6).
String agentLoopingMessage(String target) =>
    'The assistant kept redoing the same step ($target) without finishing, so '
    'it was stopped. A stronger model handles this better — switch models, or '
    'send again.';

/// The fact behind an assistant that installed but can't run: Grid tried to
/// complete the install and couldn't. Shared by the chat and the Agents screen
/// so the same problem doesn't read as two (§5); each adds its own next step,
/// because the way out differs by where you are.
const String kAgentSetupUnfinished =
    "Grid couldn't finish setting up the assistant on this computer.";

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
  // A half-finished install: the binary is there but a piece it needs isn't.
  if (isAcpSetupIncomplete(raw)) {
    // Only reached once [RepairingHermesAcpService] has already tried to finish
    // the install and failed, so this says so rather than sending the user to a
    // button that has, in effect, just been pressed for them. It still names
    // Update — a repair can fail for a reason that has since changed (no
    // network) — but never promises it will work, the trap that shipped "Hermes
    // works here" while Hermes was failing (§5).
    return '$kAgentSetupUnfinished Check your internet connection, then use '
        'Update on the Agents screen.';
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

/// The model gave the agent's loop nothing it could read — an empty or non-JSON
/// body (`Expecting value: line 1 column 1 (char 0)` is Python's JSON decoder on
/// an empty stream), or every retry came back the same way (`API call failed
/// after 3 retries: …`). Common on `auto`, when the router points at a model
/// nobody on the grid is serving.
///
/// Left alone it lands in the chat as the assistant's own words — the user reads
/// a raw Python decode error where an answer should be. Returns a plain line with
/// a next step, or null when [raw] isn't that failure. Anchored on the start of
/// the reply (and length-capped) like [friendlyAgentServerError], so an answer
/// that merely *mentions* a JSON error is never mistaken for one. The caller
/// keeps the raw text for the log (§6).
String? friendlyAgentEmptyResponse(String raw) {
  final text = raw.trim();
  final lower = text.toLowerCase();
  final isFailure =
      (lower.startsWith('api call failed after') ||
          lower.startsWith('expecting value: line 1 column 1')) &&
      text.length < 300;
  if (!isFailure) return null;
  return 'The grid returned an empty response, so there was nothing to show. '
      'Try sending again, or pick another model.';
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
