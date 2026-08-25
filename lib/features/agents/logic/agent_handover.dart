import '../../chat/logic/import/parsed_session.dart';
import '../../playground/logic/chat_message.dart';
import 'agent_catalog.dart';

/// How much of a handover may be pasted into the next agent's prompt.
///
/// **This is a budget, not a safety limit, and it is the price of the whole
/// feature.** Everything pasted here is read as the first turn's context: a
/// long chat handed over whole would spend more of the new agent's window on
/// the old agent's tool output than on the work, and could exceed it outright
/// on a small model. Roughly six thousand tokens of English — enough to carry
/// what a conversation was about and where it got to, which is what a handover
/// is for.
const int kAgentHandoverMaxChars = 24000;

/// The conversation one agent was holding, written out for the next one to read
/// at its own prompt.
///
/// Switching agent mid-chat replaces the CLI and everything it knew: the new
/// process opens on an empty session in the same folder, and the user's next
/// sentence lands with no idea what "it" refers to. This is what goes into its
/// prompt instead — unsent, so the user still decides whether the new agent
/// gets the history or a clean start.
///
/// Written in the **user's own voice**, because that is whose prompt it lands
/// in and whose Enter sends it. An instruction phrased as the app talking would
/// read to the agent as a system note it had been handed by a third party.
///
/// The tail is what survives a trim, not the head: the end of a conversation is
/// what the next sentence follows from, while the opening is the part the user
/// can retell in a line if it still matters. How much was left behind is stated
/// rather than quietly dropped (§5) — an agent that knows it is holding the last
/// third of something can ask about the rest.
///
/// Pure, and unit-tested: it is the one part of the handover that decides what
/// another model reads, and it fails silently — a paste that is subtly wrong
/// looks exactly like an agent that misunderstood.
String renderAgentHandover({
  required ParsedSession session,
  required AgentTool from,
  int maxChars = kAgentHandoverMaxChars,
}) {
  final blocks = [
    for (final message in session.messages) ?_blockOf(message, from),
  ];
  final kept = _tailWithin(blocks, maxChars);
  final dropped = blocks.length - kept.length;
  return [
    'Here is the conversation I was just having with ${from.name} in this '
        'same folder. Read it, then carry on from where it ends — no need to '
        'redo anything it already did.',
    if (dropped > 0)
      "(This is the last ${kept.length} of $dropped messages — ask me if you "
          'need the earlier part.)',
    '',
    ...kept,
  ].join('\n');
}

/// One turn as a labelled block, or null when there is nothing in it to hand
/// over — an empty message, or one that was only a picture.
String? _blockOf(ChatMessage message, AgentTool from) {
  final text = message.text.trim();
  if (text.isEmpty) return null;
  final speaker = switch (message.role) {
    ChatRole.user => 'Me',
    ChatRole.assistant => from.name,
  };
  return '$speaker: $text\n';
}

/// The last blocks that fit in [maxChars], in order.
///
/// Whole blocks only. Cutting one in half would hand the agent a sentence that
/// stops mid-word and read as the transcript itself being corrupt.
List<String> _tailWithin(List<String> blocks, int maxChars) {
  var used = 0;
  var first = blocks.length;
  while (first > 0) {
    final size = blocks[first - 1].length + 1;
    if (used + size > maxChars) break;
    used += size;
    first--;
  }
  // Not one block fits: the newest is handed over anyway, clipped, because a
  // handover that says nothing at all is the one outcome with no use.
  if (first == blocks.length && blocks.isNotEmpty) {
    return [blocks.last.substring(0, maxChars.clamp(0, blocks.last.length))];
  }
  return blocks.sublist(first);
}
