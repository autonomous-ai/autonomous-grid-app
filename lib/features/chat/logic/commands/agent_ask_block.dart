import 'dart:convert';

import 'chat_command.dart';
import 'fenced_block.dart';

/// The fence a reply uses to say the user asked for one of the app's own
/// things, in the app's own words for it.
const String kAskBlockFence = 'grid-ask';

/// The commands an assistant may relay this way.
///
/// The three that keep working after the turn ends, and the reason this exists:
/// each is a thing the app owns and the assistant cannot do for itself. The
/// rest of [ChatCommand] is the user's own housekeeping — `/clear` starting a
/// chat, `/model` changing their picker — and a reply that reached for one of
/// those would be redecorating the room it was answering in.
const Set<ChatCommand> kRelayableCommands = {
  ChatCommand.loop,
  ChatCommand.goal,
  ChatCommand.schedule,
};

/// The command [reply]'s `grid-ask` block asks for, or null when it asks for
/// nothing the app will act on.
///
/// **Why a block rather than a phrase.** The app reads a command straight out
/// of a line the user typed with a slash — `/loop 30m …`. That reading is
/// deterministic, costs nothing and answers the same way twice, which is right
/// for a set the app itself defines.
///
/// It is hopeless for the rest of how people ask. "Keep at it until I'm back in
/// the morning" names nothing the app owns, and the phrase list aimed at
/// sentences like it was wrong the day it shipped, in both directions: it read
/// "the deploy runs till morning" — someone describing a deploy — as a request
/// to loop, and it missed every way of asking that it had not been taught. The
/// app's users write in a language where "do it again" is two ordinary words,
/// which is exactly the shape a list like that cannot tell from an instruction.
///
/// So the sentence goes to the assistant, which has to read it anyway to answer
/// it, and it says back what was being asked for. No extra call, no classifier,
/// no phrase list: the model that understood the message is the one that
/// reports it.
///
/// What keeps this from being an assistant that sets its own homework:
/// - only [kRelayableCommands];
/// - only what parses as a real command line, so a half-written one does
///   nothing rather than something else;
/// - and every one of them lands somewhere the user can see and undo — a loop
///   bar, a goal bar, a row in Scheduled.
ChatCommandCall? parseAgentAsk(String reply) {
  for (final raw in fencedBlocks(reply, kAskBlockFence).reversed) {
    final line = _runLine(raw);
    if (line == null) continue;
    final call = parseChatCommand(line);
    if (call == null || !kRelayableCommands.contains(call.command)) continue;
    return call;
  }
  return null;
}

/// [text] without its `grid-ask` blocks, for showing the reply.
String stripAgentAsk(String text) => withoutFencedBlocks(text, kAskBlockFence);

/// The `run` line the block carries, or null when the block holds something
/// else. Never throws: an unreadable block is no block, and one malformed reply
/// must not take the turn down with it.
String? _runLine(String raw) {
  try {
    final decoded = jsonDecode(raw.trim());
    if (decoded is! Map) return null;
    final run = decoded['run'];
    return run is String && run.trim().isNotEmpty ? run.trim() : null;
  } on FormatException {
    return null;
  }
}
