import '../../playground/logic/playground_request.dart';
import 'agent_catalog.dart';

/// Whether the chat's agent answers this turn, rather than the grid's chat API
/// answering it directly.
///
/// The agent is the default for plain text chat — it can use tools and skills,
/// and it keeps the conversation's context itself. Making an image or a video is
/// not chat at all and always goes straight to the API. A computer where the
/// agent isn't installed also falls back to the API, so chat still answers
/// instead of failing.
///
/// A picture attached to a chat turn used to go straight to the API too, on the
/// grounds that the agent only speaks text. [agentReadsImages] is that
/// assumption becoming a question: Hermes can be pointed at a model of its own
/// for images, and when it has been, sending the turn to the API instead would
/// hand the picture to whichever model the chat happens to be using — the one
/// the composer already knows can't read it.
bool agentAnswersTurn({
  required PlaygroundModality modality,
  required bool hasAttachments,
  required bool agentInstalled,
  bool agentReadsImages = false,
}) =>
    agentInstalled &&
    modality == PlaygroundModality.text &&
    (!hasAttachments || agentReadsImages);

/// Whether the assistant answering this chat can take a picture off the chat
/// model's hands, so a turn carrying one need not go to the model that can't.
///
/// Two agents can, by two different routes:
///
/// * **Claude Code and Codex** open the file themselves — see
///   [AgentTool.opensImageFiles]. The app saves every attachment to disk before
///   the turn goes out ([buildUserTurn]) and names the path in the prompt
///   ([withAttachedMedia]); the agent reads it with its own tool. That carries
///   the picture no further than the model behind the agent can see, so
///   [modelReadsImages] — the same `vision` flag the composer's picker draws —
///   has to be true.
/// * **Hermes** is handed the bytes over ACP ([acpImages]) and, when the model
///   holding the conversation can't read them, swaps each picture for a
///   description written by its own auxiliary vision model rather than failing
///   the turn (`run_agent.py:_prepare_messages_for_non_vision_model`). That
///   needs the auxiliary model to have been chosen, and the setting that
///   chooses it exists only in a developer build — the same three conditions
///   that put it on screen in the first place.
///
/// False under Auto ([autoRouted]), whatever is installed: the agent is picked
/// per question *after* this decision is made (see `_startCommittedTurn`), so
/// there is nobody yet to ask about, and a picture routed to Hermes without an
/// auxiliary model would arrive somewhere blind. Under Auto a picture keeps
/// going straight to the grid, exactly as it always did.
///
/// Anything looser than this unlocks the composer for a turn that then fails at
/// the engine several layers down, as an error about a message it can't parse —
/// which is the exact outcome the lock exists to prevent.
bool agentReadsImagesForChat({
  required AgentTool? agent,
  required String? hermesVisionModel,
  required bool developerMode,
  bool modelReadsImages = false,
  bool autoRouted = false,
}) {
  if (agent == null || autoRouted) return false;
  if (agent.opensImageFiles) return modelReadsImages;
  return developerMode &&
      agent == AgentTool.hermes &&
      (hermesVisionModel ?? '').trim().isNotEmpty;
}
