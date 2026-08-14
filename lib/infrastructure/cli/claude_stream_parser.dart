import 'dart:convert';

import 'agent_event.dart';
import 'claude_exec_event.dart';

/// The tools Claude Code uses to change a file. Only these produce a
/// [ClaudeFileWriteStarted] / [ClaudeFileWriteFinished] pair, so the chat offers
/// to open what the agent actually wrote rather than every path it merely read.
const Set<String> kClaudeFileWriteTools = {'Write', 'Edit', 'NotebookEdit'};

/// Turns the JSONL of `claude -p --output-format stream-json` into the shapes
/// the chat already renders.
///
/// **Stateful, because the stream is.** Claude reports the answer twice over —
/// as `text_delta` chunks while it types, then as a whole `text` block when that
/// block is done — and a tool's outcome arrives in a *later* event keyed by the
/// id its call announced. Assembling either from one line in isolation is
/// impossible, so the running buffers live here, in a pure object the tests can
/// drive line by line, rather than inside the process wrapper.
///
/// The vocabulary (Claude Code 2.1, verified against the real binary):
/// `system`/`init` opens with the session id; `stream_event` wraps the vendor's
/// own SSE events (`content_block_delta` and friends); `assistant` and `user`
/// carry completed content blocks — `thinking`, `text`, `tool_use`, and
/// `tool_result` respectively; `result` closes the turn with the final answer,
/// `is_error`, and the cost. `rate_limit_event` and `system`/`thinking_tokens`
/// ride along and carry nothing to show.
class ClaudeStreamParser {
  /// Finished `text` blocks, in the order Claude closed them. Joined with the
  /// still-streaming [_partial] to make the answer shown so far.
  final _completed = <String>[];

  /// The `text` block currently arriving as deltas. Cleared when its whole
  /// block lands, which is what stops the two reports of one answer from being
  /// counted twice.
  final _partial = StringBuffer();

  /// Every tool call this turn, by the id Claude gave it, so its later result
  /// updates the same activity row instead of adding a second one.
  final _calls = <String, AgentActivity>{};

  /// Which of those calls were writing to a file, and to which path — read back
  /// when the result says whether the write landed.
  final _writes = <String, String>{};

  /// Monotonic id for thinking rows, which carry none of their own. A counter
  /// rather than a derived key so two thoughts in a row can't collide onto one
  /// feed row (the activity log upserts by id).
  var _thoughts = 0;

  /// The events worth showing from one decoded line. Empty for a line that
  /// carries nothing (reasoning-token counts, rate-limit notices, a shape from
  /// a newer build we don't know) — the parser stays tolerant rather than
  /// throwing on a stream that shifts between releases.
  ///
  /// A line tagged with `parent_tool_use_id` did not come from the agent this
  /// chat is talking to: it came from a sub-agent the `Task` tool started, whose
  /// entire working life shares this one stream. Its *steps* are still worth
  /// showing (they are real work, and a sub-agent can run for minutes), but its
  /// *words* are not the answer — see [_readBlocks].
  List<ClaudeExecEvent> read(Map<String, dynamic> event) {
    final raw = event['parent_tool_use_id'];
    final parent = raw is String && raw.isNotEmpty ? raw : null;
    return switch (event['type']) {
      'system' => _readSystem(event),
      // Deltas carry no id of their own, so a sub-agent's are told apart only
      // here — and they must be, or its half-sentences land in the middle of
      // the agent's own.
      'stream_event' => parent == null ? _readStreamEvent(event) : const [],
      'assistant' => _readBlocks(event, assistant: true, parent: parent),
      'user' => _readBlocks(event, assistant: false, parent: parent),
      'result' => _readResult(event),
      _ => const [],
    };
  }

  List<ClaudeExecEvent> _readSystem(Map<String, dynamic> event) {
    if (event['subtype'] != 'init') return const [];
    final id = event['session_id'];
    final servers = claudeServerStatuses(event['mcp_servers']);
    return [
      if (id is String && id.isNotEmpty) ClaudeSessionStarted(id),
      if (servers.isNotEmpty) ClaudeServersAnnounced(servers),
    ];
  }

  /// A vendor SSE event, forwarded verbatim by the CLI. Only the answer's text
  /// deltas are read: thinking deltas would flood the feed a character at a
  /// time, and the whole `thinking` block arrives as its own event anyway.
  List<ClaudeExecEvent> _readStreamEvent(Map<String, dynamic> event) {
    final inner = event['event'];
    if (inner is! Map) return const [];
    if (inner['type'] != 'content_block_delta') return const [];
    final delta = inner['delta'];
    if (delta is! Map || delta['type'] != 'text_delta') return const [];
    final text = delta['text'];
    if (text is! String || text.isEmpty) return const [];
    _partial.write(text);
    // A delta is by definition unfinished, so what may be divided at is still
    // the last *closed* block — passing the default here (the whole streaming
    // text) is what let a step land in the middle of a word.
    return [ClaudeMessageEvent(_answer(), settled: _settled())];
  }

  /// The completed content blocks of one `assistant` or `user` message.
  ///
  /// An `assistant` message also carries the `usage` of the request that
  /// produced it — read here rather than from the closing `result` line, which
  /// totals every request the turn made (it is what the cost is computed from)
  /// and so counts one conversation many times over.
  List<ClaudeExecEvent> _readBlocks(
    Map<String, dynamic> event, {
    required bool assistant,
    String? parent,
  }) {
    final message = event['message'];
    if (message is! Map) return const [];
    final content = message['content'];
    if (content is! List) return const [];
    return [
      // A sub-agent's request is its own conversation, not this session's, so
      // its usage says nothing about how full *this* context is — counting it
      // would have the app compacting a session that had room.
      if (assistant && parent == null)
        if (claudeContextTokens(message['usage']) case final tokens?)
          ClaudeContextUsed(tokens),
      for (final block in content)
        if (block is Map)
          ...(assistant
              ? _readAssistantBlock(block.cast<String, dynamic>(), parent)
              : _readUserBlock(block.cast<String, dynamic>(), parent)),
    ];
  }

  List<ClaudeExecEvent> _readAssistantBlock(
    Map<String, dynamic> block,
    String? parent,
  ) {
    switch (block['type']) {
      case 'text':
        // A sub-agent's prose is not the answer. It is written *to* the agent
        // that asked for it — "I'll explore the codebase systematically" — and
        // folding it in left the reply switching voice (and language) mid-turn,
        // with the agent's own sentence cut in half around it. What the
        // sub-agent found still reaches the user: it is the `Task` call's
        // result, under that step's own row.
        if (parent != null) return const [];
        final text = '${block['text'] ?? ''}';
        // The whole block is the authority for what the deltas were building.
        _partial.clear();
        if (text.trim().isEmpty) return const [];
        _completed.add(text);
        return [ClaudeMessageEvent(_answer(), settled: _settled())];
      case 'thinking':
        final thought = '${block['thinking'] ?? ''}'.trim();
        if (thought.isEmpty) return const [];
        return [
          ClaudeActivityEvent(
            AgentActivity(
              // Namespaced by owner: the agent and its sub-agents number their
              // thoughts independently, and two rows sharing an id would fold
              // onto one another in the feed.
              id: 'thinking-${parent ?? ''}-${_thoughts++}',
              kind: AgentActivityKind.thinking,
              label: thought,
              status: AgentActivityStatus.done,
              parent: parent,
            ),
          ),
        ];
      case 'tool_use':
        return _readToolUse(block, parent);
      default:
        return const [];
    }
  }

  List<ClaudeExecEvent> _readToolUse(
    Map<String, dynamic> block,
    String? parent,
  ) {
    final id = '${block['id'] ?? ''}';
    final name = '${block['name'] ?? 'tool'}';
    final rawInput = block['input'];
    final input = rawInput is Map
        ? rawInput.cast<String, dynamic>()
        : const <String, dynamic>{};

    // The to-do list is a tool call like any other, but it's the *plan*, not a
    // step — showing it as a row would list "TodoWrite" above the checklist it
    // just produced.
    if (name == 'TodoWrite') {
      return [ClaudePlanEvent(parseAgentPlan(input['todos']))];
    }

    final activity = AgentActivity(
      id: id,
      kind: claudeToolKind(name),
      label: claudeToolLabel(name, input),
      status: AgentActivityStatus.running,
      tool: name,
      parent: parent,
      // The call's own arguments, kept whole. The label picks one field out of
      // them for the row; the row can be opened, and what is behind it should be
      // what Claude actually asked for — a `Bash` step says `Bash · cd … && …`
      // in one clipped line, and the command it ran is three lines long.
      request: claudeToolRequest(name, input),
    );
    _calls[id] = activity;

    // Recorded whoever ran it: a sub-agent's write changes the same disk, and
    // the undo behind it is the only way back for either.
    final path = kClaudeFileWriteTools.contains(name)
        ? '${input['file_path'] ?? input['notebook_path'] ?? ''}'
        : '';
    if (path.isEmpty) return [ClaudeActivityEvent(activity)];
    _writes[id] = path;
    return [ClaudeActivityEvent(activity), ClaudeFileWriteStarted(id, path)];
  }

  /// A `user` message in this stream is Claude reporting back to itself: the
  /// results of the tools it just called. [parent] is carried for symmetry with
  /// the call side; the row is found by its own id, which is unique across the
  /// turn whoever ran it.
  List<ClaudeExecEvent> _readUserBlock(
    Map<String, dynamic> block,
    String? parent,
  ) {
    if (block['type'] != 'tool_result') return const [];
    final id = '${block['tool_use_id'] ?? ''}';
    final failed = block['is_error'] == true;
    final events = <ClaudeExecEvent>[];

    final call = _calls.remove(id);
    if (call != null) {
      events.add(
        ClaudeActivityEvent(
          call.settled(
            status: failed
                ? AgentActivityStatus.failed
                : AgentActivityStatus.done,
            result: claudeToolResult(block['content']),
          ),
        ),
      );
    }

    final path = _writes.remove(id);
    // A write that failed changed nothing, so there is nothing to offer to open.
    if (path != null && !failed) events.add(ClaudeFileWriteFinished(path));
    return events;
  }

  /// The turn's own last word. `result` is Claude's final answer text — taken as
  /// the authority over anything assembled from blocks, since it is what the CLI
  /// itself considers the reply.
  List<ClaudeExecEvent> _readResult(Map<String, dynamic> event) {
    final text = '${event['result'] ?? ''}';
    if (event['is_error'] == true || event['subtype'] != 'success') {
      return [
        ClaudeTurnFailed(text.trim().isEmpty ? '${event['subtype']}' : text),
      ];
    }
    _partial.clear();
    if (text.trim().isNotEmpty) {
      _completed
        ..clear()
        ..add(text);
    }
    return [
      ClaudeMessageEvent(_answer(), settled: _settled()),
      const ClaudeTurnCompleted(),
    ];
  }

  /// The answer as it stands: every finished block, plus whatever of the current
  /// one has arrived.
  String _answer() => [
    ..._completed,
    if (_partial.isNotEmpty) _partial.toString(),
  ].join('\n\n');

  /// The answer up to the last **finished** block — no half-written sentence.
  ///
  /// This is the one the chat may cut a passage at when a step arrives. The
  /// difference is not cosmetic: a step can land between two deltas of a
  /// sentence still being typed (a sub-agent's, most often), and cutting there
  /// splits the agent's own words mid-syllable — "…và chạ" above the step,
  /// "y vài ph" below it.
  String _settled() => _completed.join('\n\n');
}

/// How full the model's context was for one request, from that request's
/// `usage` — or null when the shape carries no usable figure.
///
/// Every request sends the whole conversation, so one request's input **is** the
/// context size. All three input halves count: fresh tokens, and both cache
/// figures — a cached token is still occupying the window, it was merely
/// cheaper to send. Counting only `input_tokens` is the trap here; on a
/// cache-heavy agentic turn that reads a few thousand while the real occupancy
/// is two hundred thousand.
///
/// `output_tokens` counts too, because the reply joins the conversation the
/// moment it lands and this figure is read to size the *next* turn. It is the
/// same sum Claude Code's own compaction trigger uses.
///
/// Null rather than zero when nothing parses, so a line from a build that words
/// it differently leaves the last known figure standing instead of resetting it
/// and calling a full session empty.
int? claudeContextTokens(Object? usage) {
  if (usage is! Map) return null;
  int field(String name) => (usage[name] as num?)?.toInt() ?? 0;
  final total =
      field('input_tokens') +
      field('cache_read_input_tokens') +
      field('cache_creation_input_tokens') +
      field('output_tokens');
  return total > 0 ? total : null;
}

/// The `mcp_servers` array of an `init` line, read as name → status.
///
/// Lenient like the rest of the parser: an entry without a name is skipped
/// rather than fatal, and an unknown shape yields nothing at all.
Map<String, String> claudeServerStatuses(Object? node) {
  if (node is! List) return const {};
  return {
    for (final entry in node)
      if (entry is Map && entry['name'] is String)
        '${entry['name']}': '${entry['status'] ?? 'unknown'}',
  };
}

/// Which icon a tool call gets in the activity feed. Claude names its tools, so
/// this is a lookup rather than a guess: a shell command reads as a command, the
/// two web tools as web look-ups, and everything else — the file tools, the
/// searches, MCP servers — as a tool.
AgentActivityKind claudeToolKind(String name) => switch (name) {
  'Bash' || 'BashOutput' || 'KillShell' => AgentActivityKind.command,
  'WebSearch' || 'WebFetch' => AgentActivityKind.web,
  _ when isBrowserTool(name) => AgentActivityKind.web,
  _ => AgentActivityKind.tool,
};

/// The MCP servers a browser lane hands the turn: the Claude in Chrome
/// extension, and the app's own browser over the DevTools protocol.
const List<String> kBrowserToolPrefixes = [
  'mcp__claude-in-chrome__',
  'mcp__chrome-devtools__',
];

/// Whether [name] is a call into a browser rather than into this computer.
///
/// The feed is the only place a user sees that an agent is driving their
/// browser — there is no button that turned it on and none that shows it is
/// running — so a browser step reading `mcp__claude-in-chrome__navigate_page`
/// is a step nobody can act on.
bool isBrowserTool(String name) => kBrowserToolPrefixes.any(name.startsWith);

/// A tool call's arguments, as the fold under its row shows them.
///
/// Verified against the real binary (Claude Code 2.1, `claude -p --output-format
/// stream-json`): every `tool_use` block carries its whole `input` map — `Bash`
/// gives `{command, description}`, `Read` gives `{file_path, limit}`, an MCP
/// call gives whatever that server declared. So the fold shows the call itself,
/// pretty-printed, rather than the app's own one-line summary of it a second
/// time.
///
/// A lone `command` (which is what `Bash` mostly is) is unwrapped to the bare
/// command line: a shell command wearing JSON quotes and `\n` escapes is harder
/// to read than the thing itself, and it is the one payload a user is most
/// likely to want to copy.
String? claudeToolRequest(String name, Map<String, dynamic> input) {
  if (input.isEmpty) return null;
  final command = input['command'];
  // Only the shell tool, by name. Gating on "has a `command` key" alone unwrapped
  // calls that merely happen to have one — a browser server's
  // `{command: 'click', selector: '#buy'}` came out as the word `click`, with
  // the half that said what was clicked thrown away.
  if (name == 'Bash' && command is String && command.trim().isNotEmpty) {
    return clipToolPayload(command);
  }
  try {
    return clipToolPayload(const JsonEncoder.withIndent('  ').convert(input));
  } on JsonUnsupportedObjectError {
    // A shape `dart:convert` can't walk. The row and its title still stand;
    // only the fold goes, which is better than dropping the step.
    return null;
  }
}

/// What a tool handed back, as the fold under its row shows it.
///
/// Verified against the real binary: a `tool_result` block carries `content`,
/// which is a plain string for the tools people actually watch (`Read` returns
/// the numbered lines, `Bash` returns its output, and a failure returns
/// `Exit code 1` and the error). Tools that answer with structured blocks —
/// images, some MCP servers — send the array form instead, so both are read and
/// anything that is neither is dropped rather than stringified into `[{…}]`.
///
/// Returned **uncapped**: [AgentActivity.settled] is what caps it, and clipping
/// here as well counted the cut against the already-cut string — a 200KB read
/// came out saying 26 characters were dropped instead of 196,050.
String? claudeToolResult(Object? content) {
  if (content is String) return content;
  if (content is! List) return null;
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is Map && block['type'] == 'text' && block['text'] is String) {
      buffer.writeln(block['text'] as String);
    }
  }
  return buffer.toString();
}

/// The one line the feed shows for a tool call — the thing the call is *about*,
/// not the tool's name, wherever the input carries it. A row reading "Bash"
/// eight times says nothing; the commands do.
String claudeToolLabel(String name, Map<String, dynamic> input) {
  if (isBrowserTool(name)) return browserToolLabel(name, input);
  final detail = switch (name) {
    'Bash' => input['command'],
    'WebSearch' => input['query'],
    'WebFetch' => input['url'],
    'Task' => input['description'],
    'Glob' || 'Grep' => input['pattern'],
    _ => _fileName(input['file_path'] ?? input['notebook_path']),
  };
  final text = '${detail ?? ''}'.trim();
  return text.isEmpty ? name : '$name · $text';
}

/// One browser step, said the way the user would say it: "Browser · navigate
/// page · example.com".
///
/// The server name is dropped rather than shown. Which of the two lanes drove
/// the browser is a routing detail the log already carries; on screen it would
/// only ask the user to learn the difference between two things that look
/// identical from where they sit.
String browserToolLabel(String name, Map<String, dynamic> input) {
  final action = name.split('__').last.replaceAll('_', ' ').trim();
  final detail =
      input['url'] ??
      input['query'] ??
      input['text'] ??
      input['value'] ??
      input['selector'] ??
      input['uid'];
  final text = '${detail ?? ''}'.trim();
  return [
    'Browser',
    if (action.isNotEmpty) action,
    if (text.isNotEmpty) text,
  ].join(' · ');
}

/// The last segment of a path — the feed has one line, and an absolute path
/// spends all of it on folders the user already knows they're in.
String _fileName(Object? path) {
  final text = '${path ?? ''}'.trim();
  if (text.isEmpty) return '';
  final cut = text.lastIndexOf('/');
  return cut == -1 ? text : text.substring(cut + 1);
}
