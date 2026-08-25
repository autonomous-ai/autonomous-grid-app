import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_session_files.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../playground/logic/chat_message.dart';
import 'conversation.dart';
import 'import/claude_session_parser.dart';
import 'import/codex_session_parser.dart';
import 'import/parsed_session.dart';

/// [messages] as plain text, for the clipboard — one labelled block per turn, in
/// the order they were said.
///
/// Three labels, not two: a goal's next step and a loop's beat go out under the
/// user's role but nobody typed them, and a copied transcript that puts "You:"
/// in front of one is the same lie the bubble used to tell (see [TurnOrigin]).
///
/// Takes the turns rather than the chat, because for a chat shown as a terminal
/// they are not on the chat at all — see [ChatTranscript].
String transcriptText(List<ChatMessage> messages) => [
  for (final m in messages) '${_transcriptSpeaker(m)}: ${m.text}',
].join('\n\n');

String _transcriptSpeaker(ChatMessage message) {
  if (message.role == ChatRole.assistant) return 'Assistant';
  return message.sentBy.isFromApp ? 'Grid' : 'You';
}

/// Reads a chat out to plain text, from wherever its conversation actually
/// lives.
///
/// **Copy transcript used to hand back an empty clipboard for Claude Code and
/// Codex, under a toast that said it had worked.** A chat in either of those
/// lanes is the CLI's own screen: the program holds the conversation and the app
/// commits nothing to [Conversation.messages], so a copy that read the chat read
/// a list that is empty for life. The turns are in the agent's session file, and
/// this app already knows how to read both — the same parsers the import lane
/// uses, which also strip the blocks each tool injects into the user's turn (an
/// IDE selection, the environment, a slash command's text) so the copy is the
/// conversation rather than the machinery around it.
///
/// Reading the file rather than the terminal's own scrollback is deliberate: the
/// scrollback is a rendering — box-drawing, spinners, and every line hard-wrapped
/// at the column count the pane happened to have.
final chatTranscriptProvider = Provider<ChatTranscript>(ChatTranscript.new);

class ChatTranscript {
  ChatTranscript(this._ref);

  final Ref _ref;

  final AgentSessionFiles _files = AgentSessionFiles();

  /// [chat] as plain text, or null when there is nothing to copy — no turns
  /// here and no session on disk.
  ///
  /// Null rather than an empty string so the caller can say so. A chat whose CLI
  /// has been opened but never spoken to has no file at all: Claude Code writes
  /// its session on the first turn, not at start-up (see [AgentSessionFiles]).
  Future<String?> textOf(Conversation chat) async {
    if (chat.messages.isNotEmpty) return transcriptText(chat.messages);
    final session = await _agentSession(chat);
    if (session == null || session.messages.isEmpty) return null;
    return transcriptText(session.messages);
  }

  /// The newest session this chat has on disk that still has a conversation in
  /// it, or null.
  ///
  /// [Conversation.resume] is newest-first, so the first hit is the conversation
  /// the user is looking at. Every failure answers null: another tool's file
  /// owes this app no shape, and a copy that cannot be built has to say so
  /// rather than put a stack trace on the clipboard. Logged, because a copy that
  /// quietly returned nothing is exactly the bug this replaced (§6).
  Future<ParsedSession?> _agentSession(Conversation chat) async {
    for (final point in chat.resume) {
      final agent = agentToolById(point.agent);
      if (agent == null) continue;
      try {
        final parsed = await _read(agent, point.sessionId);
        if (parsed != null && parsed.messages.isNotEmpty) return parsed;
      } on Object catch (error) {
        _ref
            .read(appLogProvider)
            .failure(
              'agent',
              "couldn't read the conversation ${agent.name} is holding in "
                  '"${chat.title}"',
              error: error,
            );
      }
    }
    return null;
  }

  /// One agent's session file, parsed — null when it has none, or when the
  /// agent keeps no file to read (Hermes holds its conversation in a live
  /// process, so there is nothing on disk once it has exited).
  Future<ParsedSession?> _read(AgentTool agent, String sessionId) async {
    final file = switch (agent) {
      AgentTool.claude => await _files.claudeSession(sessionId),
      AgentTool.codex => await _files.codexSession(sessionId),
      AgentTool.hermes => null,
    };
    if (file == null) return null;
    final lines = await file.readAsLines();
    return switch (agent) {
      AgentTool.claude => parseClaudeSession(
        sessionId: sessionId,
        lines: lines,
      ),
      AgentTool.codex => parseCodexSession(
        fallbackSessionId: sessionId,
        lines: lines,
      ),
      AgentTool.hermes => null,
    };
  }
}
