import 'dart:convert';

import 'chat_loop.dart';

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
/// [start] is the block asking for a loop that does not exist yet, and it is
/// the one field here the *user* is behind rather than the assistant. The app
/// reads "lặp lại mỗi 30 phút" out of a sentence deterministically, but nobody
/// can list every way a person says "keep going until I'm back" — so when the
/// reading finds nothing, the assistant that just read the message says whether
/// it was a repeat. It costs no round-trip: that turn was happening anyway.
typedef LoopPace = ({
  Duration? next,
  String? why,
  bool quiet,
  bool stop,
  bool start,
});

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
  final blocks = _fencedBlocks(reply);
  for (final raw in blocks.reversed) {
    final decoded = _decode(raw);
    if (decoded == null) continue;
    final why = '${decoded['why'] ?? ''}'.trim();
    return (
      next: _delay(decoded['next']),
      why: why.isEmpty ? null : why,
      quiet: decoded['quiet'] == true,
      stop: decoded['stop'] == true,
      start: decoded['start'] == true,
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
String stripLoopPaceBlock(String text) {
  if (!text.contains(kLoopBlockFence)) return text;
  return text.replaceAll(_fence, '').trimRight();
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

/// ```grid-loop … ``` anywhere in the text, innards only.
final RegExp _fence = RegExp(
  '^[ \\t]*```[ \\t]*$kLoopBlockFence[ \\t]*\\r?\\n(.*?)^[ \\t]*```[ \\t]*\$',
  multiLine: true,
  dotAll: true,
);

List<String> _fencedBlocks(String reply) =>
    _fence.allMatches(reply).map((m) => m.group(1) ?? '').toList();

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
