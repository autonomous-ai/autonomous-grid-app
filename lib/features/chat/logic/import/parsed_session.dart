import '../../../playground/logic/chat_message.dart';
import '../conversation.dart';

/// Which tool a transcript was read out of.
///
/// Only the two agents that keep a resumable session on disk: Claude Code and
/// Codex both write one file per session and take an id to continue it, which
/// is what makes an imported chat continuable rather than a museum piece.
/// Hermes holds its conversation in a live process, so there is nothing on disk
/// to read and nothing to resume once it has exited.
enum ImportedAgent {
  /// `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`, one JSON event per line.
  claude(id: 'claude', label: 'Claude Code'),

  /// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl`, whose first
  /// line is a `session_meta` header.
  codex(id: 'codex', label: 'Codex');

  const ImportedAgent({required this.id, required this.label});

  /// The `AgentTool` id, so an imported chat resumes on the same agent that
  /// wrote it — see [AgentResumePoint.agent].
  final String id;

  /// What the user reads: the tool's own name, not this app's word for it.
  final String label;
}

/// A transcript read off another tool's session file, before it becomes a chat.
///
/// The parsers' whole output, and deliberately not a [Conversation]: a
/// conversation needs an id this app assigns and a project this app resolves,
/// neither of which a file on disk can answer for. Keeping the two apart is
/// what lets the parsers stay pure functions over a list of lines — no clock,
/// no filesystem, no providers — which is the only reason they can be trusted
/// against formats that change under us.
class ParsedSession {
  const ParsedSession({
    required this.agent,
    required this.sessionId,
    required this.title,
    required this.messages,
    required this.startedAt,
    required this.updatedAt,
    this.workdir,
    this.model,
    this.toolCalls = 0,
    this.truncatedMessages = 0,
  });

  final ImportedAgent agent;

  /// The tool's own session id — what `--resume` takes.
  final String sessionId;

  /// The name to show. The tool's own title where it wrote one down (Claude's
  /// `ai-title` line, Codex's `thread_name`), else derived from the first thing
  /// the user said.
  final String title;

  final List<ChatMessage> messages;

  /// When the session's first and last events happened. Both are read from the
  /// file's own stamps rather than from the clock, so importing a chat twice a
  /// week apart produces the same dates.
  final DateTime startedAt;
  final DateTime updatedAt;

  /// The folder the session ran in — its `cwd`. Null when the file never said,
  /// which costs the chat its project link and its ability to resume.
  final String? workdir;

  /// The model that answered, as the other tool named it (`claude-opus-5`,
  /// `gpt-5.4-codex`). Shown in the transcript footer; it is not a model this
  /// grid can necessarily serve.
  final String? model;

  /// How many tool steps were folded into the prose (see [foldedToolCall]).
  ///
  /// Counted so the import screen can say what it is about to do to them,
  /// rather than let the user discover the difference afterwards.
  final int toolCalls;

  /// How many messages were clipped for length (see [kMaxImportedMessageChars]).
  final int truncatedMessages;

  /// A rough size for the picker, so a 4 MB session is visibly a 4 MB session
  /// before it is imported into a store that reads every chat at startup.
  int get characters {
    var total = 0;
    for (final message in messages) {
      total += message.text.length;
    }
    return total;
  }

  /// Turn this into a chat, under an [id] the caller has minted.
  ///
  /// [projectId] is resolved by the caller from [workdir]: this layer knows the
  /// folder the session ran in, but which of the user's projects that *is* — or
  /// whether it is one at all — is not a question a transcript can answer.
  Conversation toConversation({
    required String id,
    String? projectId,
  }) => Conversation(
    id: id,
    title: title,
    // The other tool's model id, kept as-is. It is what actually answered,
    // and the composer treats a model it can't serve as a preference rather
    // than a promise — the same way a project's remembered model is treated.
    model: model ?? '',
    createdAt: startedAt,
    updatedAt: updatedAt,
    messages: messages,
    projectId: projectId,
    // The tool named this session itself, or it was derived from the user's
    // own first line. Either way nothing should rename it later: the agent's
    // naming pass runs off a chat's *first* exchange, and re-running it on a
    // transcript of fifty turns would title it after a conversation that
    // ended weeks ago.
    titleLocked: true,
  );
}

/// Blocks the two tools inject into the user's turn — the IDE's open file and
/// selection, the environment, the loaded skills and plugins, the text of a
/// slash command the user ran.
///
/// They wear the user's role and are not what the user said. Left in, a
/// transcript opens with several screens of machine-written context before the
/// first question — and the chat gets titled after it, since a title is taken
/// from the first line of the first message.
///
/// One list for both tools rather than one each: they are different products
/// that inject the *same* things, and the overlap is not a coincidence — the
/// first version of this had `<system-reminder>` on the Claude side only and
/// `<ide_opened_file>` on the Codex side only, which left 22 injected blocks in
/// one imported Claude transcript because that session had been driven from an
/// IDE too.
const _kInjectedTags = {
  // Claude Code
  'system-reminder',
  'local-command-caveat',
  'local-command-stdout',
  'command-name',
  'command-message',
  'command-args',
  // Codex
  'app-context',
  'apps_instructions',
  'collaboration_mode',
  'environment_context',
  'model_switch',
  'multi_agent_mode',
  'plugins_instructions',
  'recommended_plugins',
  'skills_instructions',
  'turn_aborted',
  'user_instructions',
  // Both, from their IDE extensions
  'ide_opened_file',
  'ide_selection',
};

/// Placeholders left where a block the tool couldn't represent used to be —
/// `[external unsupported block: image]`. Not something anybody said.
final _unsupportedBlock = RegExp(r'\[external unsupported block:[^\]]*\]');

/// [text] with every injected context block removed — see [_kInjectedTags].
///
/// Whole runs, not just the opening tag: these blocks carry their content
/// between a matched pair, and stripping only the marker would leave the
/// content behind wearing the user's voice. An *unclosed* tag takes the rest of
/// the text with it — that only happens where the block was cut off, so what
/// follows it is the tail of the same injected block and nothing else.
String stripInjectedContext(String text) {
  var out = text.replaceAll(_unsupportedBlock, '');
  for (final tag in _kInjectedTags) {
    out = out
        .replaceAll(RegExp('<$tag>.*?</$tag>', dotAll: true), '')
        .replaceAll(RegExp('<$tag>.*', dotAll: true), '');
  }
  return out.trim();
}

/// The chat id an imported session becomes.
///
/// Derived from the source rather than minted from the clock, so importing the
/// same session twice *updates* one chat instead of leaving two. That is what
/// makes re-importing a session that has been talked in since work at all: the
/// second import overwrites the first chat's file, and a conversation that grew
/// by ten messages in Claude Code grows by ten messages here.
///
/// Sanitized because the id is used as a file name — both tools use plain UUIDs
/// today, and a chat id is not the place to trust that.
String conversationIdFor(ParsedSession parsed) {
  final id = '${parsed.agent.id}-${parsed.sessionId}'.replaceAll(
    RegExp(r'[^A-Za-z0-9._-]'),
    '_',
  );
  return id.length <= 120 ? id : id.substring(0, 120);
}

/// The longest one imported message is kept at.
///
/// A tool result in a Codex rollout runs to several thousand characters, and a
/// long session holds hundreds of them. `ChatStore` reads *every* chat into
/// memory at startup, so an unclipped import is not a big chat — it is a slow
/// launch, for as long as the chat exists.
const int kMaxImportedMessageChars = 12000;

/// What is appended where a message was clipped. Said out loud rather than
/// trailing off, because a transcript that silently stops mid-sentence reads as
/// a bug in the agent that wrote it.
const String kTruncationNotice =
    '\n\n_… the rest of this message was not imported (too long)._';

/// [text] clipped to [kMaxImportedMessageChars], with a note saying so.
///
/// Returns the text unchanged when it fits, so the common case allocates
/// nothing and the notice only ever appears where something was really lost.
String clipImported(String text) {
  if (text.length <= kMaxImportedMessageChars) return text;
  return text.substring(0, kMaxImportedMessageChars) + kTruncationNotice;
}

/// [merged] finished: adjacent step blocks joined, then every turn clipped.
///
/// **After merging, never before.** Both tools write one line per API
/// round-trip, so a turn arrives in pieces and [mergeTurns] joins them — clip
/// the pieces and the join puts them straight back over the limit. Measured on
/// a real Codex rollout that way: a cap of 12,000 produced turns of 52,705 and
/// 84,138 characters, because seven clipped pieces are one turn seven times too
/// long. The cap has to be applied to the thing it is a cap on.
({List<ChatMessage> messages, int clipped}) finishTurns(
  List<ChatMessage> merged,
) {
  final out = <ChatMessage>[];
  var clipped = 0;
  for (final message in merged) {
    final joined = _joinStepBlocks(message.text);
    final text = clipImported(joined);
    if (text.length != joined.length) clipped++;
    out.add(text == message.text ? message : message.copyWith(text: text));
  }
  return (messages: out, clipped: clipped);
}

/// Runs of tool steps, welded into one block.
///
/// Every step is emitted as a one-line fenced block of its own (see
/// [foldedToolCall]) because the parsers meet them one at a time — Claude's
/// arrive as blocks inside a turn, Codex's as separate stream items joined
/// later. This closes the seam afterwards, so a turn that ran eighty-five
/// commands draws *one* block of eighty-five lines instead of eighty-five
/// blocks. That count is real: it is the worst turn in the largest session on
/// this machine, and as separate blocks it was a wall.
String _joinStepBlocks(String text) => text.replaceAll('```\n\n```\n', '');

/// The longest a step's detail runs before it is cut.
const int _maxToolDetail = 110;

/// A path longer than this is shown by its last two segments alone.
const int _maxPathLength = 44;

/// One tool step, as a line the transcript can show.
///
/// This app's own transcript draws a step as a row with an icon and a status —
/// but that shape (`TurnPart`) does not exist on this branch, so an imported
/// step becomes markdown. A **fenced block**, not a blockquote with the command
/// in inline code, which is what this did first and what made an imported chat
/// look wrong beside the tool it came from:
///
/// - Inline code does not survive a line break, so a multi-line command had to
///   be flattened. A heredoc script came out as one unreadable run of tokens,
///   cut mid-word at the cap — the single worst thing on the screen.
/// - A run of them was a run of quoted paragraphs, each with its own margins.
///   Monospace lines in one block read as a list of commands, which is what
///   they are, and [_joinStepBlocks] is what welds the run together.
///
/// The result of the call is deliberately not carried. It is the bulk of every
/// session file — thousands of characters per step, most of it a directory
/// listing the agent has long since acted on — and a transcript is read to
/// follow what happened, not to re-read what the tools printed.
String foldedToolCall({required String tool, String? detail}) {
  final name = tool.trim().isEmpty ? 'tool' : tool.trim();
  final line = _stepDetail(detail);
  if (line.isEmpty) return '```\n$name\n```';
  // Padded so the details line up down the block once several steps join. A
  // name longer than the pad simply keeps its two spaces.
  return '```\n${name.padRight(7)}  $line\n```';
}

/// The one line that says what a step did.
///
/// The *first* line of the detail rather than all of it flattened: a shell
/// heredoc or a multi-line patch says what it is in its opening words, and the
/// rest only becomes noise once the newlines are gone. An ellipsis marks that
/// there was more, so nothing is quietly dropped.
String _stepDetail(Object? raw) {
  if (raw is! String) return '';
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final lines = trimmed.split('\n');
  var head = _oneLine(lines.first);
  if (head.startsWith('/') && head.length > _maxPathLength) {
    head = _shortPath(head);
  }
  if (head.length > _maxToolDetail) {
    return '${head.substring(0, _maxToolDetail).trimRight()}…';
  }
  return lines.length > 1 ? '$head …' : head;
}

/// The tail of a long absolute path — the two segments a person reads.
///
/// `/Users/…/lib/features/plugins/logic/plugins_controller.dart` becomes
/// `logic/plugins_controller.dart`. The full path identifies the file to a
/// machine; these two identify it to the person who wrote it, and the same
/// ninety-character prefix repeated across two thousand steps identifies
/// nothing at all.
String _shortPath(String path) {
  final parts = path.split('/')..removeWhere((p) => p.isEmpty);
  if (parts.length <= 2) return path;
  return parts.sublist(parts.length - 2).join('/');
}

/// [text] as a single line fit for a step: runs of whitespace collapse to one
/// space, and any backtick is defused — three in a row would close the fence
/// the line sits in and spill the rest of the turn onto the page.
String _oneLine(String text) =>
    text.replaceAll('`', "'").replaceAll(RegExp(r'\s+'), ' ').trim();

/// The message list with empty turns dropped and neighbours of one role merged.
///
/// Both tools write one line per API round-trip, so a single turn arrives as
/// several: the agent says a sentence, calls a tool, reads the result, says the
/// next sentence — four lines, one turn. Left as they are, the transcript draws
/// four bubbles from the same speaker and reads as an agent talking to itself.
List<ChatMessage> mergeTurns(List<ChatMessage> messages) {
  final out = <ChatMessage>[];
  for (final message in messages) {
    if (message.text.trim().isEmpty && message.media.isEmpty) continue;
    final last = out.isEmpty ? null : out.last;
    if (last == null || last.role != message.role) {
      out.add(message);
      continue;
    }
    out[out.length - 1] = last.copyWith(
      text: '${last.text}\n\n${message.text}'.trim(),
      // The later half of a merged turn is the one that carries the finished
      // turn's stamps — an early line has no model on it yet.
      model: message.model ?? last.model,
    );
  }
  return out;
}

/// A title for a session the tool never named, from the first thing the user
/// said — the same rule the app's own chats follow, so an imported chat sits in
/// the sidebar looking like the ones beside it.
String titleFromMessages(List<ChatMessage> messages) =>
    deriveConversationTitle(messages);
