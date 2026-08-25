import 'dart:convert';

import 'chat_loop.dart';
import 'fenced_block.dart';

/// The fence a self-paced loop's reply ends with to say what happens next.
///
/// Named like `chart` (see `ChartSpec`) and taught the same way — by a skill
/// card, `grid-loop`, because a format nothing announces is a format no agent
/// will ever emit.
const String kLoopBlockFence = 'grid-loop';

/// What the assistant asked the loop to do after this iteration.
///
/// The whole point of self-paced mode: the one that just did the work is the
/// one that knows whether the thing being watched is about to change, and
/// whether there is anything left to watch at all. Before this the app asked a
/// *different* model, which had seen a single message of the turn and could
/// never say "we're done" — so a loop set going overnight kept asking long
/// after its answer had arrived.
///
/// [next] is how long to wait, null when the block named no readable gap.
/// [why] is the one line the loop bar shows. [quiet] marks an iteration where
/// nothing changed, so a night of them collapses to a count instead of filling
/// the transcript. [stop] ends the loop — the normal way a finished job stops,
/// rather than running until the user notices or the seven days run out.
///
/// Starting a loop is not one of these. That is [parseAgentAsk]'s `grid-ask`
/// block, which relays *any* of the app's own commands the user asked for —
/// this one only ever paces a loop that is already running.
typedef LoopPace = ({Duration? next, String? why, bool quiet, bool stop});

/// The `grid-loop` block in [reply], or null when it holds none.
///
/// The **last** block wins: a reply that shows the format before using it (or
/// one that changed its mind mid-answer) ends with the decision it settled on,
/// and reading the first would act on the example.
///
/// Never throws — an unreadable block is no block, and the caller falls back to
/// asking the way it always did. Anything else would let one malformed reply
/// stop a loop the user is relying on.
LoopPace? parseLoopPaceBlock(String reply) {
  final blocks = fencedBlocks(reply, kLoopBlockFence);
  for (final raw in blocks.reversed) {
    final decoded = _decode(raw);
    if (decoded == null) continue;
    final why = '${decoded['why'] ?? ''}'.trim();
    return (
      next: _delay(decoded['next']),
      why: why.isEmpty ? null : why,
      quiet: decoded['quiet'] == true,
      stop: decoded['stop'] == true,
    );
  }
  return null;
}

/// [text] without its `grid-loop` blocks, for showing the reply.
///
/// The block is how the assistant talks to the app, not to the user: left in,
/// every iteration of an overnight loop ends with a line of JSON nobody asked
/// to read. Stripped here rather than hidden by the renderer so the transcript
/// that gets stored, re-sent as history and exported is the clean one.
String stripLoopPaceBlock(String text) =>
    withoutFencedBlocks(text, kLoopBlockFence);

/// [text] without the line the app added to it, for showing the beat.
///
/// The footer is the app talking to the model, and it is on the *user's* own
/// message — so left in, a loop beat draws the user asking for a `grid-loop`
/// block in words they never typed. [_tidyLoopBeat] takes it back off the
/// stored message, but only once the beat has been answered: on a turn that
/// runs for minutes, or one the app was closed during, that is far too late to
/// be the only guard. This one is at the drawing, where the timing cannot slip.
///
/// It cannot simply be dropped from the message: the prompt an agent is sent is
/// built from the transcript, so what is stored *is* what is asked.
String withoutLoopBeatFooter(String text) {
  if (!text.contains(kLoopBlockFence)) return text;
  for (final footer in [
    loopBeatFooter(selfPaced: true),
    loopBeatFooter(selfPaced: false),
  ]) {
    final at = text.lastIndexOf(footer);
    if (at != -1) return text.substring(0, at).trimRight();
  }
  return text;
}

/// The line the app adds to a loop iteration's prompt, asking for the block
/// back.
///
/// Sent with the beat and then taken back off the stored message once the beat
/// has been paced (see `_tidyLoopBeat`), so the assistant reads it exactly on
/// the turn it applies to instead of finding fifty copies of it in the history
/// of an overnight run.
///
/// [selfPaced] decides which half is asked for: a loop on the user's own
/// interval has no gap to choose, but every loop can reach the end of its job.
String loopBeatFooter({required bool selfPaced}) => selfPaced
    ? 'When you have answered, end your reply with a `$kLoopBlockFence` '
          'block saying when to run this again '
          '(`{"next": "20m", "why": "…"}`), `{"quiet": true}` if nothing '
          'changed, or `{"stop": true, "why": "…"}` if there is nothing '
          'left to check.'
    : 'When you have answered, end your reply with a `$kLoopBlockFence` '
          'block — `{"quiet": true}` if nothing changed, or '
          '`{"stop": true, "why": "…"}` if there is nothing left to check. '
          'Leave it out to keep going as scheduled.';

/// The block's JSON object, or null when it holds something else. A bare `{}`
/// counts: it is a well-formed "carry on as you were".
Map<String, Object?>? _decode(String raw) {
  try {
    final decoded = jsonDecode(raw.trim());
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

/// The gap [raw] names, in the same `45s` / `20m` / `2h` grammar `/loop` itself
/// reads — one spelling of a duration in this app, not two — clamped to what a
/// self-paced loop may wait.
Duration? _delay(Object? raw) {
  if (raw is! String) return null;
  final parsed = parseLoopInterval(raw.trim());
  if (parsed == null) return null;
  if (parsed < kMinPacedDelay) return kMinPacedDelay;
  return parsed > kMaxPacedDelay ? kMaxPacedDelay : parsed;
}
