import 'dart:convert';

import '../../../infrastructure/cli/hermes_acp_service.dart';
import '../../../infrastructure/cli/hermes_acp_setup.dart';
import '../../network/logic/app_guide_snippets.dart';

/// A turn that ended with nothing to show. Shared by every agent so a silent
/// Hermes and a silent Codex read the same to the user.
const String kAgentNoAnswer = "The agent didn't return an answer.";

/// A turn that laid out a plan and then stopped before finishing it — no steps
/// ticked off, nothing built. Shared by both agents so a stalled Hermes and a
/// stalled Codex read the same. The chat pairs it with the switch-agent button,
/// so "let another agent take this chat" is an offer to try, not a promise (§5).
const String kAgentStalledPlan =
    'The agent planned the work but stopped before finishing it. Try sending '
    'again, or let another agent take this chat.';

/// A turn that went silent — the assistant sent nothing for a long stretch and
/// wasn't waiting on the user either, so it's stuck. A frequent cause: it
/// started a command that never returns (a dev server) and waited on it. Ended
/// so the chat doesn't spin forever; shares the other turn-end lines' shape (§5)
/// — the raw silence is a gap in the log, nothing to humanize away.
const String kAgentUnresponsive =
    'The assistant went quiet — it can get stuck on a command that never '
    'finishes, like starting a server. The turn was stopped; send again, or let '
    'another agent take this chat.';

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

/// A turn that ended in the assistant's own error, with nothing streamed and no
/// reason we recognise. Says the turn failed rather than that the agent had
/// nothing to say ([kAgentNoAnswer]) — the two look identical in the chat and
/// have different fixes. The raw reason is logged where it arrives.
const String kAgentTurnFailed =
    "The assistant couldn't answer that. Try sending again, or pick another "
    'model.';

/// A turn that ended because a message never reached the assistant's process —
/// the pipe to it broke, or it died under one. Nothing it was waiting on can
/// arrive now, so the turn is over and the session with it.
///
/// Kept apart from [kAgentTurnFailed]: this isn't the assistant failing to
/// answer, so "pick another model" would point at the wrong lever. The next
/// message starts a fresh session, which is why "send again" is the whole fix.
const String kAgentLostContact =
    'Grid lost its connection to the assistant on this computer, so the turn '
    'stopped. Send again — that starts it up fresh.';

/// [kAgentLostContact] when [raw] is that failure, else null.
///
/// Matched on the line the session emits ([kAcpLostContact]) — the same shape as
/// the other `friendlyAgent*` helpers, except the words being read are the app's
/// own. The raw error stays in the log, where it names the pipe (§6).
String? friendlyAgentLostContact(String raw) =>
    raw.contains(kAcpLostContact) ? kAgentLostContact : null;

/// The assistant couldn't read the connection Grid wrote for the model it was
/// pointed at.
///
/// Hermes says it two ways, both meaning the same thing: `Unknown provider
/// 'grid'. Check 'hermes model' …` when it reads the provider and doesn't know
/// it, and `No LLM provider configured. Run 'hermes model' …` when it refuses a
/// session over it. Either kills every turn — chat, a scheduled task, Telegram —
/// on a build too old for the named-provider config a responses-only model
/// needs. The model is the thing the user can change, so the line names both
/// levers: update, or pick something else.
const String kAgentProviderUnknown =
    "The assistant didn't recognise the connection Grid set up for that model. "
    'Update it on the Agents screen, or pick another model.';

/// [kAgentProviderUnknown] when [raw] is that failure, else null — so the
/// handshake path and the turn path can both catch it without either owning the
/// wording.
///
/// Matched on the provider name the app itself writes, and on Hermes's
/// "no provider configured" refusal: an assistant complaining about some *other*
/// provider is a different problem and keeps its own words.
String? friendlyAgentUnknownProvider(String raw) {
  final lower = raw.toLowerCase();
  final unusable =
      lower.contains("unknown provider '$kHermesGridProviderKey'") ||
      lower.contains('no llm provider configured');
  return unusable ? kAgentProviderUnknown : null;
}

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
  // A build that can't read the connection Grid wrote for this model. Checked
  // before the install cases: the assistant is installed and running fine — it
  // is this *model* it can't be pointed at — so "finish the install" would send
  // the user to the wrong lever.
  final provider = friendlyAgentUnknownProvider(raw);
  if (provider != null) return provider;
  // A half-finished install: the binary is there but a piece it needs isn't.
  if (isAcpSetupIncomplete(raw)) {
    // Only reached once [RepairingHermesAcpService] has already tried to finish
    // the install and failed, so this says so rather than sending the user to a
    // button that has, in effect, just been pressed for them. It still names
    // Update — a repair can fail for a reason that has since changed (no
    // network) — but never promises it will work, the trap that shipped "Hermes
    // works here" while Hermes was failing (§5).
    return '$kAgentSetupUnfinished Use Update on the Agents screen to finish it '
        '— it needs a connection to download the rest.';
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
