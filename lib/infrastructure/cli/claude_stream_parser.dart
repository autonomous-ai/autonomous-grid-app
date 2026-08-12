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
  List<ClaudeExecEvent> read(Map<String, dynamic> event) =>
      switch (event['type']) {
        'system' => _readSystem(event),
        'stream_event' => _readStreamEvent(event),
        'assistant' => _readBlocks(event, assistant: true),
        'user' => _readBlocks(event, assistant: false),
        'result' => _readResult(event),
        _ => const [],
      };

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
    return [ClaudeMessageEvent(_answer())];
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
  }) {
    final message = event['message'];
    if (message is! Map) return const [];
    final content = message['content'];
    if (content is! List) return const [];
    return [
      if (assistant)
        if (claudeContextTokens(message['usage']) case final tokens?)
          ClaudeContextUsed(tokens),
      for (final block in content)
        if (block is Map)
          ...(assistant
              ? _readAssistantBlock(block.cast<String, dynamic>())
              : _readUserBlock(block.cast<String, dynamic>())),
    ];
  }

  List<ClaudeExecEvent> _readAssistantBlock(Map<String, dynamic> block) {
    switch (block['type']) {
      case 'text':
        final text = '${block['text'] ?? ''}';
        // The whole block is the authority for what the deltas were building.
        _partial.clear();
        if (text.trim().isEmpty) return const [];
        _completed.add(text);
        return [ClaudeMessageEvent(_answer())];
      case 'thinking':
        final thought = '${block['thinking'] ?? ''}'.trim();
        if (thought.isEmpty) return const [];
        return [
          ClaudeActivityEvent(
            AgentActivity(
              id: 'thinking-${_thoughts++}',
              kind: AgentActivityKind.thinking,
              label: thought,
              status: AgentActivityStatus.done,
            ),
          ),
        ];
      case 'tool_use':
        return _readToolUse(block);
      default:
        return const [];
    }
  }

  List<ClaudeExecEvent> _readToolUse(Map<String, dynamic> block) {
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
    );
    _calls[id] = activity;

    final path = kClaudeFileWriteTools.contains(name)
        ? '${input['file_path'] ?? input['notebook_path'] ?? ''}'
        : '';
    if (path.isEmpty) return [ClaudeActivityEvent(activity)];
    _writes[id] = path;
    return [ClaudeActivityEvent(activity), ClaudeFileWriteStarted(id, path)];
  }

  /// A `user` message in this stream is Claude reporting back to itself: the
  /// results of the tools it just called.
  List<ClaudeExecEvent> _readUserBlock(Map<String, dynamic> block) {
    if (block['type'] != 'tool_result') return const [];
    final id = '${block['tool_use_id'] ?? ''}';
    final failed = block['is_error'] == true;
    final events = <ClaudeExecEvent>[];

    final call = _calls.remove(id);
    if (call != null) {
      events.add(
        ClaudeActivityEvent(
          AgentActivity(
            id: call.id,
            kind: call.kind,
            label: call.label,
            status: failed
                ? AgentActivityStatus.failed
                : AgentActivityStatus.done,
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
    return [ClaudeMessageEvent(_answer()), const ClaudeTurnCompleted()];
  }

  /// The answer as it stands: every finished block, plus whatever of the current
  /// one has arrived.
  String _answer() => [
    ..._completed,
    if (_partial.isNotEmpty) _partial.toString(),
  ].join('\n\n');
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
