import '../../playground/logic/playground_request.dart';

/// Whether the agent (Hermes) answers this turn, rather than the grid's chat
/// API answering it directly.
///
/// The agent is the default for plain text chat — it can use tools and skills,
/// and it keeps the conversation's context itself. It only speaks text, though,
/// so anything with a picture in it goes straight to the API: generating an
/// image or a video, and a vision turn that carries attachments. A computer
/// where the agent isn't installed also falls back to the API, so chat still
/// answers instead of failing.
bool agentAnswersTurn({
  required PlaygroundModality modality,
  required bool hasAttachments,
  required bool agentInstalled,
}) => agentInstalled && !hasAttachments && modality == PlaygroundModality.text;
