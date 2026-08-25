import '../../../../infrastructure/cli/agent_event.dart';
import '../../../playground/logic/chat_message.dart';
import '../chat_title.dart';
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
    // The tool that wrote the transcript is the tool that carries it on. An
    // imported chat has a session on disk and an id to resume it with, and both
    // belong to one agent — reopening it under whichever agent the picker
    // happened to be showing would start a stranger in a conversation it has
    // never read.
    agent: agent.id,
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

/// How much of a step's output an *import* keeps.
///
/// Far less than the live transcript's `kStoredResultLimit`, and for a reason
/// that branch's own note spells out: on disk a result is one row of one step
/// of a turn from weeks ago. It sizes that limit for a turn running "twenty-odd
/// commands" — a fair description of a live turn, and not of an imported
/// session. The largest here holds **2,089** steps, whose outputs come to 2 MB
/// raw; kept at the live limit they were 1.6 MB of shell output in one chat
/// file, re-encoded every time that chat is spoken in.
///
/// Enough to see what came back — a few lines — which is what the row is for.
/// The rest was never going to be read out of a transcript; it is still in the
/// tool's own session file, which this import never touches.
const int kImportedResultLimit = 240;

/// One step of a turn, still being assembled.
///
/// Mutable, and that is the whole point: a tool call and its outcome arrive as
/// two separate things on both streams — Claude answers a `tool_use` block with
/// a `tool_result` in the *next* message, Codex a `function_call` with a
/// `function_call_output` further down. [TurnStep] holds an immutable
/// [AgentActivity], so the parsers assemble here and build once the outcome is
/// known.
class StepDraft {
  StepDraft({
    required this.id,
    required this.tool,
    required this.kind,
    this.request,
  });

  /// The tool call's own id on the stream — what its result is keyed to.
  final String id;

  /// The tool's name as the agent calls it: `Bash`, `Read`, `exec_command`.
  final String tool;

  final AgentActivityKind kind;

  /// What was asked of the tool — the command line, or the arguments.
  final String? request;

  /// What came back. Null while unmatched, which is how a step ends up
  /// [AgentActivityStatus.unknown].
  String? result;

  /// Whether the tool reported the call as failed.
  bool failed = false;

  /// This step as the transcript stores it.
  ///
  /// A step with no result settles as `unknown`, never as done: the file said
  /// nothing about how it went, and a tick would vouch for a command that may
  /// have failed — the same reasoning [AgentActivityStatus.unknown] was added
  /// for on a live turn that was stopped mid-tool.
  AgentActivity build() => AgentActivity(
    id: id,
    kind: kind,
    label: stepLabel(tool: tool, request: request),
    status: result == null
        ? AgentActivityStatus.unknown
        : (failed ? AgentActivityStatus.failed : AgentActivityStatus.done),
    tool: tool,
    request: request,
    result: _trimResult(result),
  );

  /// [text] cut to [kImportedResultLimit], saying so rather than trailing off.
  static String? _trimResult(String? text) {
    if (text == null || text.length <= kImportedResultLimit) return text;
    return '${text.substring(0, kImportedResultLimit).trimRight()}\n…';
  }
}

/// One turn under construction: what was said and what was run, in order.
class TurnDraft {
  TurnDraft(this.role, {this.model, this.sentAt});

  final ChatRole role;

  /// The model that answered, on an assistant turn.
  String? model;

  /// The source event's time. Later pieces replace it when a turn is merged,
  /// so the finished message says when its final visible piece landed.
  DateTime? sentAt;

  /// Prose passages ([String]) and steps ([StepDraft]), interleaved in the
  /// order they happened — which is the order the chat replays them in.
  final List<Object> items = [];

  void say(String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) items.add(trimmed);
  }

  void ran(StepDraft step) => items.add(step);

  bool get isEmpty => items.isEmpty;

  /// Whether anything here needs the timeline view at all. A turn that only
  /// spoke is stored the plain way, exactly as every reply saved before turns
  /// recorded their own order — see `ChatBubble`, which draws `parts` only when
  /// they are there.
  bool get hasSteps => items.any((item) => item is StepDraft);

  /// The prose alone, which is what search, the sidebar preview and the model
  /// itself read. The steps are *shown* from [parts]; they are not what the
  /// turn said.
  String get prose => items.whereType<String>().join('\n\n').trim();

  List<TurnPart> get parts => [
    for (final item in items)
      if (item is StepDraft)
        TurnStep(item.build())
      else
        TurnText(item as String),
  ];
}

/// [drafts] with empty turns dropped and neighbours of one role merged.
///
/// Both tools write one line per API round-trip, so a single turn arrives as
/// several: the agent says a sentence, calls a tool, reads the result, says the
/// next sentence — four lines, one turn. Left as they are, the transcript draws
/// four bubbles from the same speaker and reads as an agent talking to itself.
List<TurnDraft> mergeDrafts(List<TurnDraft> drafts) {
  final out = <TurnDraft>[];
  for (final draft in drafts) {
    if (draft.isEmpty) continue;
    final last = out.isEmpty ? null : out.last;
    if (last == null || last.role != draft.role) {
      out.add(draft);
      continue;
    }
    last.items.addAll(draft.items);
    // The later half of a merged turn carries the stamps — an early line has no
    // model on it yet.
    last.model = draft.model ?? last.model;
    last.sentAt = draft.sentAt ?? last.sentAt;
  }
  return out;
}

/// [drafts] as the messages a chat is made of, and how many were clipped.
///
/// The prose is capped here, on whole turns, not on the lines they were
/// assembled from. Measured the other way round: a cap of 12,000 produced turns
/// of 52,705 and 84,138 characters, because seven clipped pieces are one turn
/// seven times too long. The cap has to be applied to the thing it is a cap on.
///
/// The steps are *not* capped here — each one caps its own payload as it is
/// written to disk (`kStoredResultLimit`), which is the right place for it: the
/// limit belongs to the row, not to the turn holding the rows.
({List<ChatMessage> messages, int clipped}) finishDrafts(
  List<TurnDraft> drafts, {
  required String agentId,
}) {
  final out = <ChatMessage>[];
  var clipped = 0;
  for (final draft in drafts) {
    final prose = clipImported(draft.prose);
    if (prose.length != draft.prose.length) clipped++;
    if (draft.role == ChatRole.user) {
      out.add(
        ChatMessage(role: ChatRole.user, text: prose, sentAt: draft.sentAt),
      );
      continue;
    }
    out.add(
      ChatMessage(
        role: ChatRole.assistant,
        text: prose,
        parts: draft.hasSteps ? draft.parts : const [],
        agent: agentId,
        model: draft.model,
        sentAt: draft.sentAt,
      ),
    );
  }
  return (messages: out, clipped: clipped);
}

/// The longest a step's label runs before it is cut. The label is the one line
/// the row shows folded; the full command stays in [StepDraft.request].
const int _maxLabel = 110;

/// A path longer than this is shown by its last two segments alone.
const int _maxPathLength = 44;

/// The one line a step's row shows when it is folded shut.
///
/// The *first* line of the request rather than all of it flattened: a shell
/// heredoc or a multi-line patch says what it is in its opening words, and the
/// rest only becomes noise once the newlines are gone. Opening the row shows
/// the request whole, so nothing is lost by keeping this short.
String stepLabel({required String tool, String? request}) {
  final name = tool.trim().isEmpty ? 'tool' : tool.trim();
  final raw = request?.trim() ?? '';
  if (raw.isEmpty) return name;
  final lines = raw.split('\n');
  var head = _oneLine(lines.first);
  if (head.startsWith('/') && head.length > _maxPathLength) {
    head = _shortPath(head);
  }
  if (head.length > _maxLabel) {
    head = '${head.substring(0, _maxLabel).trimRight()}…';
  } else if (lines.length > 1) {
    head = '$head …';
  }
  return '$name  $head';
}

/// The tail of a long absolute path — the two segments a person reads.
///
/// `/Users/…/lib/features/plugins/logic/plugins_controller.dart` becomes
/// `logic/plugins_controller.dart`. The full path identifies the file to a
/// machine; these two identify it to the person who wrote it, and the same
/// ninety-character prefix repeated across two thousand rows identifies nothing
/// at all.
String _shortPath(String path) {
  final parts = path.split('/')..removeWhere((p) => p.isEmpty);
  if (parts.length <= 2) return path;
  return parts.sublist(parts.length - 2).join('/');
}

/// Which icon the row gets, from the tool's name.
///
/// Named rather than guessed from the payload: every agent words its tools
/// differently, and the name is the one thing each of them does report.
AgentActivityKind stepKindFor(String tool) {
  final name = tool.toLowerCase();
  const shell = ['bash', 'exec', 'shell', 'terminal', 'command', 'run'];
  const web = ['web', 'search', 'fetch', 'browser'];
  if (shell.any(name.contains)) return AgentActivityKind.command;
  if (web.any(name.contains)) return AgentActivityKind.web;
  return AgentActivityKind.tool;
}

/// [text] as a single line: runs of whitespace collapse to one space.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A title for a session the tool never named, from the first thing the user
/// said — the same rule the app's own chats follow, so an imported chat sits in
/// the sidebar looking like the ones beside it.
String titleFromMessages(List<ChatMessage> messages) =>
    deriveConversationTitle(messages);
