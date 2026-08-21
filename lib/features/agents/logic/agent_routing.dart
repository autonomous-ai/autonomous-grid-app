import '../../playground/logic/playground_request.dart';

/// Whether the agent (Hermes) answers this turn, rather than the grid's chat
/// API answering it directly.
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
