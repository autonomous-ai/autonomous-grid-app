import 'dart:convert';

import 'agent_event.dart';
import 'agent_question.dart';
import 'claude_exec_event.dart';
import 'claude_exec_service.dart' show kClaudeSessionSchedulerTools;
import 'model_control_tokens.dart';

/// The tools Claude Code uses to change a file. Only these produce a
/// [ClaudeFileWriteStarted] / [ClaudeFileWriteFinished] pair, so the chat offers
/// to open what the agent actually wrote rather than every path it merely read.
const Set<String> kClaudeFileWriteTools = {'Write', 'Edit', 'NotebookEdit'};

/// Tools whose *result* is the CLI coaching the model, not telling the user
/// anything.
///
/// `EnterPlanMode` answers with a page of instructions addressed to the
/// assistant — "You should now focus on exploring the codebase… DO NOT write or
/// edit any files yet" — and `ExitPlanMode` with the sentence that releases it.
/// Both landed in the transcript verbatim, which read as the app telling the
/// user what to do. The row still shows (the agent did switch modes), the
/// payload behind it doesn't.
const Set<String> kClaudeCoachingTools = {'EnterPlanMode', 'ExitPlanMode'};

/// The plan-mode tools in the user's words. Every other tool row is titled by
/// what it acted on ([claudeToolLabel]); these two act on nothing, so without
/// this they show the CLI's own identifier and nothing else.
const Map<String, String> kClaudePhrasedTools = {
  'EnterPlanMode': 'Planning before changing anything',
  'ExitPlanMode': 'Finished the plan',
};

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
/// `is_error`, and the cost — unless `system`/`background_tasks_changed` has
/// said work is still running, in which case it closes only the model's turn
/// and a second one follows (see [ClaudeTurnWaiting]). `rate_limit_event` and
/// `system`/`thinking_tokens` ride along and carry nothing to show.
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

  /// Passages closed by an earlier `result` of this same turn — the answer
  /// Claude gave before its background work came back. Kept apart from
  /// [_completed] because a `result` line *replaces* the blocks it closes, and
  /// the second turn's `result` must replace only its own. See
  /// [ClaudeTurnWaiting].
  final _sealed = <String>[];

  /// What the CLI says is still running in the background, by task id — the
  /// whole list, as its last `background_tasks_changed` line stated it. Empty
  /// is the CLI saying nothing is, which is what lets a `result` close the turn.
  final _background = <String, String>{};

  /// The tool call each background task was started by, so its notification
  /// can settle that row with the real outcome. Captured at `task_started`,
  /// which arrives *before* the call's own placeholder result ("launched in
  /// background") removes it from [_calls].
  final _backgroundCalls = <String, AgentActivity>{};

  /// The scheduler calls this turn made, by call id, until their result says
  /// whether they took: a `ScheduleWakeup` that errored booked nothing.
  final _scheduling = <String, Map<String, dynamic>>{};

  /// The wake-up the model booked and the CLI has yet to fire — how long it
  /// asked for and why. Null when none is booked, or once it has fired.
  ///
  /// This is Claude Code's own `/loop`: the model ends its turn, the CLI sleeps
  /// the delay and starts the next turn by itself (`command_lifecycle`, then a
  /// second `init`). Measured on 2.1.247 (2026-08-27): it works under `-p` as
  /// long as the process is alive to sleep — which is what a turn that is not
  /// ended at its first `result` gives it.
  ({int delaySeconds, String reason})? _wakeup;

  /// Session-only cron jobs alive in this process: `CronCreate` less
  /// `CronDelete`, both counted only when their result says they took. Like a
  /// wake-up they fire only while the process lives.
  var _crons = 0;

  /// Finished background tasks the CLI has told the model about and not yet
  /// answered for — a `task_notification` is a message queued for the model,
  /// and the CLI starts a turn to read it (`init`, then `result`).
  ///
  /// Counted because the notification can land **before** the turn's own
  /// `result`: a sub-agent that only says "pong" is done in twenty seconds,
  /// while a slow model takes forty to write "launched". Measured 2026-08-27 on
  /// 2.1.247 — the app read the emptied task list, saw nothing pending at the
  /// `result`, closed stdin and killed the process five seconds later, in the
  /// middle of the turn that was about to report "pong". The TUI, alive for as
  /// long as it is open, reported it.
  var _owed = 0;

  /// How many times this turn has been left waiting, so each wait is its own
  /// row in the timeline rather than one row moved about.
  var _waits = 0;

  /// The events worth showing from one decoded line. Empty for a line that
  /// carries nothing (reasoning-token counts, rate-limit notices, a shape from
  /// a newer build we don't know) — the parser stays tolerant rather than
  /// throwing on a stream that shifts between releases.
  ///
  /// A line tagged with `parent_tool_use_id` did not come from the agent this
  /// chat is talking to: it came from a sub-agent the `Agent` tool started, whose
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

  List<ClaudeExecEvent> _readSystem(Map<String, dynamic> event) =>
      switch (event['subtype']) {
        'init' => _readInit(event),
        'background_tasks_changed' => _readBackgroundTasks(event['tasks']),
        'task_started' => _readTaskStarted(event),
        'task_notification' => _readTaskNotification(event),
        'task_progress' => _readTaskProgress(event),
        _ => const [],
      };

  /// The session opening — or, after background work, re-opening: the CLI
  /// starts the turn that reads a task's notification with a second `init`
  /// carrying the same id, so this is read the same way both times.
  List<ClaudeExecEvent> _readInit(Map<String, dynamic> event) {
    final id = event['session_id'];
    final servers = claudeServerStatuses(event['mcp_servers']);
    return [
      if (id is String && id.isNotEmpty) ClaudeSessionStarted(id),
      if (servers.isNotEmpty) ClaudeServersAnnounced(servers),
      // A second `init` while waiting is the next turn starting — the tick a
      // wake-up booked, or the turn that reads a task's notification. The
      // wake-up has fired (the model books the next one afresh, if it wants
      // one), and the wait is over.
      ..._endWait(fired: true),
    ];
  }

  /// The turn that reads queued notifications has started: they are no longer
  /// owed. Every one of them, since one turn reads the whole queue.
  void _startTurn() => _owed = 0;

  /// Whether the only pending thing is the CLI's turn on a notification —
  /// see [ClaudeTurnWaiting.reportsOnly].
  bool get _reportsOnly =>
      _background.isEmpty && _wakeup == null && _crons == 0;

  /// End a wait the CLI never came back from: the notification it owed a turn
  /// for was, after all, read inside the turn that just ended. The service
  /// calls this once [kClaudeReportGrace] has passed with no `init`.
  List<ClaudeExecEvent> giveUpWaiting() {
    if (!_waiting) return const [];
    _owed = 0;
    return [..._endWait(fired: false), const ClaudeTurnCompleted()];
  }

  /// Settle the open waiting row, if there is one. [fired] says a booked
  /// wake-up went off, so it is no longer pending.
  List<ClaudeExecEvent> _endWait({required bool fired}) {
    if (fired) {
      _wakeup = null;
      _startTurn();
    }
    if (!_waiting) return const [];
    _waiting = false;
    return [
      ClaudeActivityEvent(_waitRow.settled(status: AgentActivityStatus.done)),
    ];
  }

  /// The CLI's own list of what is running in the background, replacing the
  /// last one wholesale. An emptied list settles the waiting row, if one is up.
  List<ClaudeExecEvent> _readBackgroundTasks(Object? tasks) {
    _background.clear();
    if (tasks is List) {
      for (final task in tasks) {
        if (task is! Map) continue;
        final id = '${task['task_id'] ?? ''}';
        if (id.isEmpty) continue;
        _background[id] = '${task['description'] ?? task['task_type'] ?? id}';
      }
    }
    if (_background.isNotEmpty || !_waiting) return const [];
    // Still waiting on a tick: the row stays up, saying what is left.
    if (_hasPendingWork) return [ClaudeActivityEvent(_waitRow)];
    return _endWait(fired: false);
  }

  /// Whether the turn has work the CLI will still act on after a `result`.
  bool get _hasPendingWork =>
      _background.isNotEmpty || _owed > 0 || _wakeup != null || _crons > 0;

  /// What is still pending, one line each — the log's and the feed's account.
  List<String> get _pending => [
    ..._background.values,
    if (_wakeup case final wakeup?)
      'next tick in ${wakeup.delaySeconds}s'
          '${wakeup.reason.isEmpty ? '' : ' — ${wakeup.reason}'}',
    if (_crons > 0) '$_crons scheduled job${_crons == 1 ? '' : 's'}',
    if (_owed > 0) '$_owed finished task${_owed == 1 ? '' : 's'} to report',
  ];

  List<ClaudeExecEvent> _readTaskStarted(Map<String, dynamic> event) {
    final task = '${event['task_id'] ?? ''}';
    final call = _calls['${event['tool_use_id'] ?? ''}'];
    // Only the tasks the CLI itself lists as background: a sub-agent's own
    // shell command is reported through the same line and is nobody's to wait
    // for.
    if (call != null && _background.containsKey(task)) {
      _backgroundCalls[task] = call;
    }
    return const [];
  }

  /// A running background task's account of itself — for a workflow, which of
  /// its agents are done. The row of the call that started it carries the line
  /// while it runs; the notification replaces it with the outcome.
  ///
  /// This is all the stream carries of a workflow's inside. A sub-agent the
  /// `Agent` tool starts reports every step on stdout under its parent, but a
  /// workflow's agents never do — measured 2026-08-27 on 2.1.247: not one line
  /// of a whole workflow tagged `parent_tool_use_id`. The TUI's "0/3 agents
  /// done" is this same event, drawn; without it the chat showed a workflow as
  /// one row that said "launched" until it said "completed".
  List<ClaudeExecEvent> _readTaskProgress(Map<String, dynamic> event) {
    final call = _backgroundCalls['${event['task_id'] ?? ''}'];
    if (call == null) return const [];
    final line = claudeTaskProgress(event);
    if (line == null) return const [];
    return [
      ClaudeActivityEvent(
        call.settled(status: AgentActivityStatus.running, result: line),
      ),
    ];
  }

  /// A background task finished: the row of the call that started it gets the
  /// outcome, replacing the "launched in background" its own result carried.
  List<ClaudeExecEvent> _readTaskNotification(Map<String, dynamic> event) {
    // Owed whether or not the call that started it is known: the CLI queues
    // the notification for the model either way, and will start a turn on it.
    _owed++;
    final call = _backgroundCalls.remove('${event['task_id'] ?? ''}');
    if (call == null) return const [];
    final failed = event['status'] != 'completed';
    return [
      ClaudeActivityEvent(
        call.settled(
          status: failed
              ? AgentActivityStatus.failed
              : AgentActivityStatus.done,
          result: claudeToolResult(event['summary']),
        ),
      ),
    ];
  }

  /// Whether the last `result` left the turn waiting on background work.
  var _waiting = false;

  /// The feed row that says the turn is waiting, and on what. One id per wait
  /// ([_waits]), so the event that ends it settles the same row and a later
  /// wait in the same turn gets a row of its own, after the text it follows.
  AgentActivity get _waitRow => AgentActivity(
    id: 'background-wait-$_waits',
    kind: AgentActivityKind.tool,
    // A tick is a tick whether a wake-up or a session cron books it: the cron
    // arm used to fall through to the count below and read "0 background
    // tasks", which is a number nobody asked for about a thing nobody started.
    label: _wakeup != null || _crons > 0
        ? 'Waiting for the next tick'
        // Nothing still running, only news the model has yet to read.
        : _background.isEmpty
        ? 'Waiting for the report on background work'
        : _background.length == 1
        ? 'Waiting for background work to finish'
        : 'Waiting for ${_background.length} background tasks to finish',
    status: AgentActivityStatus.running,
    tool: 'Background',
    request: _pending.join('\n'),
  );

  /// Messages the CLI fed back to itself this turn, for one row id each.
  var _feedbacks = 0;

  /// The feed row for [text] the CLI handed back to the model on its own —
  /// hook output, mostly. Done on arrival: it is a thing that was said, not a
  /// thing that runs.
  AgentActivity _feedbackRow(String text) => AgentActivity(
    id: 'feedback-${++_feedbacks}',
    kind: AgentActivityKind.tool,
    label: 'Fed back to the agent',
    status: AgentActivityStatus.done,
    tool: 'Claude Code',
    result: text,
  );

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
    // The model spoke again: the call that produced this block read every
    // notification queued before it, so none of them is owed a turn any more.
    // A sub-agent's block says nothing about what the agent itself has read.
    if (parent == null) _owed = 0;
    switch (block['type']) {
      case 'text':
        // A sub-agent's prose is not the answer. It is written *to* the agent
        // that asked for it — "I'll explore the codebase systematically" — and
        // folding it in left the reply switching voice (and language) mid-turn,
        // with the agent's own sentence cut in half around it.
        //
        // It is still the only account of what a sub-agent is *doing*, though,
        // and a delegated stretch can hold the screen for minutes. So it is kept
        // as a step of that sub-agent's own rather than dropped: it lands in the
        // group under the row that started it, where it reads as that agent's
        // note, and nowhere near the reply.
        if (parent != null) return _readNote(block, parent);
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

  /// One passage a sub-agent wrote, as a step of its own.
  ///
  /// Filed as [AgentActivityKind.thinking] because that is what it is from the
  /// user's side — working-out, not an answer — and because the feed already
  /// draws that kind the right way: the whole passage goes behind the fold
  /// rather than being clipped into a row, which a paragraph has to be.
  ///
  /// Shares [_thoughts] with the thinking rows and takes a prefix of its own, so
  /// a note and a thought landing back to back cannot collide onto one feed row.
  List<ClaudeExecEvent> _readNote(Map<String, dynamic> block, String parent) {
    final note = '${block['text'] ?? ''}'.trim();
    if (note.isEmpty) return const [];
    return [
      ClaudeActivityEvent(
        AgentActivity(
          id: 'note-$parent-${_thoughts++}',
          kind: AgentActivityKind.thinking,
          label: note,
          status: AgentActivityStatus.done,
          parent: parent,
        ),
      ),
    ];
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

    // Neither is a step the user watches happen: this one is a question, and it
    // belongs where they can answer it, not folded into a row. Falls through to
    // an ordinary row when the call carries nothing answerable, so a malformed
    // question is still visible rather than swallowed.
    if (name == 'AskUserQuestion') {
      final questions = parseAgentQuestions(input['questions']);
      if (questions.isNotEmpty) return [ClaudeQuestionsEvent(questions)];
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
    if (kClaudeSessionSchedulerTools.contains(name)) _scheduling[id] = input;

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
  /// results of the tools it just called. The row is found by its own id, which
  /// is unique across the turn whoever ran it; [parent] decides only whose
  /// context the pictures in it land in — a sub-agent's are its own
  /// conversation's, exactly as its `usage` is (see [_readBlocks]).
  List<ClaudeExecEvent> _readUserBlock(
    Map<String, dynamic> block,
    String? parent,
  ) {
    // …with one exception: the CLI feeds its own hooks' words back to the
    // model here, as plain text rather than a tool result — a Stop hook's
    // verdict on a `/goal` the CLI is driving, say. It is the agent talking to
    // itself, so it is not part of the answer; it is a step, because the CLI
    // showed it and the app shows what the CLI sent, nothing more and nothing
    // less.
    if (block['type'] == 'text') {
      final text = '${block['text'] ?? ''}'.trim();
      if (text.isEmpty) return const [];
      return [ClaudeActivityEvent(_feedbackRow(text))];
    }
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
            result: kClaudeCoachingTools.contains(call.tool)
                ? null
                : claudeToolResult(block['content']),
          ),
        ),
      );
    }

    final path = _writes.remove(id);
    // A write that failed changed nothing, so there is nothing to offer to open.
    if (path != null && !failed) events.add(ClaudeFileWriteFinished(path));

    if (_scheduling.remove(id) case final input? when !failed) {
      _bookScheduling(call?.tool, input);
    }

    // What a picture just cost the session, which the reported figure does not
    // say — see [claudeMediaTokens].
    final media = parent == null ? claudeMediaTokens(block['content']) : 0;
    if (media > 0) events.add(ClaudeMediaUsed(media));
    return events;
  }

  /// A scheduler call that took: a wake-up booked (or cancelled with
  /// `stop`), a cron job created or deleted.
  ///
  /// Counted only from a result that is not an error, because a refused call
  /// booked nothing — and a wake-up the app then waited for would be a turn
  /// that never ends.
  void _bookScheduling(String? tool, Map<String, dynamic> input) {
    switch (tool) {
      case 'ScheduleWakeup':
        if (input['stop'] == true) {
          _wakeup = null;
          return;
        }
        final delay = input['delaySeconds'];
        _wakeup = (
          delaySeconds: delay is num ? delay.round() : 0,
          reason: '${input['reason'] ?? ''}'.trim(),
        );
      case 'CronCreate':
        _crons++;
      case 'CronDelete':
        if (_crons > 0) _crons--;
      default:
    }
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
    if (!_hasPendingWork) {
      return [
        ClaudeMessageEvent(_answer(), settled: _settled()),
        const ClaudeTurnCompleted(),
      ];
    }
    // Not the end: the CLI will run another turn when the background work
    // comes back or the wake-up fires (see [ClaudeTurnWaiting]). What was said
    // stays said — moved out of the reach of that turn's own `result` — and
    // the chat is shown what it is waiting on rather than a bubble that has
    // quietly stopped.
    _sealed.addAll(_completed);
    _completed.clear();
    _waiting = true;
    _waits++;
    return [
      ClaudeMessageEvent(_answer(), settled: _settled()),
      ClaudeActivityEvent(_waitRow),
      ClaudeTurnWaiting(List.unmodifiable(_pending), reportsOnly: _reportsOnly),
    ];
  }

  /// The answer as it stands: every finished block, plus whatever of the current
  /// one has arrived.
  /// Everything the agent has said this turn, as one passage.
  ///
  /// Cut at a chat-template marker if one arrived: a model served over the grid
  /// can overrun its stop token, and what comes after is not the agent's — see
  /// [stripControlTokens].
  String _answer() => stripControlTokens(
    [
      ..._sealed,
      ..._completed,
      if (_partial.isNotEmpty) _partial.toString(),
    ].join('\n\n'),
  );

  /// The answer up to the last **finished** block — no half-written sentence.
  ///
  /// This is the one the chat may cut a passage at when a step arrives. The
  /// difference is not cosmetic: a step can land between two deltas of a
  /// sentence still being typed (a sub-agent's, most often), and cutting there
  /// splits the agent's own words mid-syllable — a half-written word above the
  /// step,
  /// "y vài ph" below it.
  String _settled() =>
      stripControlTokens([..._sealed, ..._completed].join('\n\n'));
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
/// **It is not the whole occupancy, and on a chat with pictures it is nowhere
/// near it** — see [claudeMediaTokens], which is what the app adds on top.
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

/// Roughly 32 base64 characters to a token — see [claudeMediaTokens].
const int _base64CharsPerToken = 32;

/// What the pictures in one tool result cost the context, estimated from the
/// payload itself, because the reported figure does not count them.
///
/// **Measured against the relay itself, 2026-08-21**, three `POST /v1/messages`
/// on `Qwen/Qwen3.8-27B-FP8-Workshop`, reading `usage.input_tokens` back:
///
/// | request | reported |
/// |---|---|
/// | `hi` | 2 |
/// | `hi` + a 176 KB JPEG (2838×1030) | **2** |
/// | ~7000 tokens of prose | 6944 |
///
/// Text is counted exactly. A picture is counted as **nothing at all** — the
/// same request either side of one moved the figure by zero tokens. That is why
/// this is added to [claudeContextTokens] rather than replacing it: the reported
/// number is true about the half it covers.
///
/// What it costs: the chat that died the same day (session `b3959598`) read 31
/// screenshots, and the engine refused the next request saying the prompt held
/// at least 236545 while the last report was 40593 — ~196000 tokens of pictures
/// nothing on the wire mentioned, ~6300 a picture. **Both** compaction paths read
/// only the figure that missed them, Claude Code's own auto-compact (threshold
/// 167000 on that config) and this app's `needsCompaction` (ceiling 204800), so
/// neither could fire and the conversation died of a context both believed was
/// 40k.
///
/// So the app counts what it can see go past: the base64 in the `tool_result`,
/// at [_base64CharsPerToken]. Those 31 images carried 7146216 characters over
/// that ~196000 — nearer 36 to a token — so the divisor here deliberately reads
/// **high**, and the two ways to be wrong are not symmetric: too high summarizes
/// a conversation sooner than it had to, too low loses the turn, the session and
/// the work in it (the same reasoning as `kAssumedContextWindow`).
///
/// **`TODO(BE)`: this is a guess standing in for a number the engine already
/// counts.** A relay that reports image tokens in `usage` makes every line of
/// this unnecessary; until then no caller can know what a chat with pictures in
/// it really holds.
int claudeMediaTokens(Object? content) {
  if (content is! List) return 0;
  var total = 0;
  for (final block in content) {
    if (block is! Map || block['type'] != 'image') continue;
    final source = block['source'];
    final data = source is Map ? source['data'] : null;
    if (data is String) total += data.length ~/ _base64CharsPerToken;
  }
  return total;
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
  // The plan itself, as the markdown the model wrote — the one payload here a
  // user reads rather than inspects, and JSON quoting turns it into one long
  // line of `\n`.
  final plan = input['plan'];
  if (name == 'ExitPlanMode' && plan is String && plan.trim().isNotEmpty) {
    return clipToolPayload(plan.trim());
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
  if (kClaudePhrasedTools[name] case final phrase?) return phrase;
  if (name.startsWith('mcp__')) return mcpToolLabel(name, input);
  final detail = switch (name) {
    'Bash' => input['command'],
    'WebSearch' => input['query'],
    'WebFetch' => input['url'],
    // `Agent` is what this tool is called in Claude Code 2.x; `Task` was its
    // name before, and both are kept because the app pins no version of the
    // CLI. Measured across the recent sessions on this machine: 31 `Agent`
    // calls, no `Task` at all — so the row this line titles had been reading
    // "Agent" and nothing else, with the description it carries thrown away.
    'Agent' || 'Task' => input['description'],
    // Which skill, not that a skill ran.
    'Skill' => input['skill'],
    // The next tick and why, or that the loop is being ended.
    'ScheduleWakeup' =>
      input['stop'] == true
          ? 'stop'
          : 'in ${input['delaySeconds']}s · ${input['reason'] ?? ''}',
    'CronCreate' => input['cron'],
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

/// A connector's tool, as `server · tool` rather than the wire identifier.
///
/// MCP names arrive as `mcp__<server>__<tool>` —
/// `mcp__plugin_playwright_playwright__browser_navigate` is one real row — and
/// a line of that spends its whole width on plumbing the user never chose by
/// name. The browser servers have their own label ([browserToolLabel]) because
/// their action words are worth reading; this is every other connector.
String mcpToolLabel(String name, Map<String, dynamic> input) {
  final parts = name.split('__').where((p) => p.isNotEmpty).toList();
  final server = parts.length > 1 ? parts[1].replaceAll('_', ' ') : '';
  final tool = parts.length > 2 ? parts.last.replaceAll('_', ' ') : '';
  final detail = '${input['query'] ?? input['target'] ?? ''}'.trim();
  return [
    if (server.isNotEmpty) server,
    if (tool.isNotEmpty) tool,
    if (detail.isNotEmpty) detail,
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

/// One line saying where a background task has got to, from a
/// `task_progress` event — or null when the event says nothing readable.
///
/// A workflow is counted by its agents, in the TUI's own words ("1/3 agents
/// done"), followed by the phase and the agent last heard from. Anything else
/// falls back to the task's last tool, its tool-call count and how long it has
/// run.
String? claudeTaskProgress(Map<String, dynamic> event) {
  final progress = event['workflow_progress'];
  if (progress is List) {
    final agents = [
      for (final step in progress)
        if (step is Map && step['type'] == 'workflow_agent') step,
    ];
    if (agents.isNotEmpty) {
      final done = agents.where((a) => a['state'] == 'done').length;
      final current = agents.lastWhere(
        (a) => a['state'] != 'done',
        orElse: () => agents.last,
      );
      final phase = '${current['phaseTitle'] ?? ''}'.trim();
      final label = '${current['label'] ?? ''}'.trim();
      return '$done/${agents.length} agents done'
          '${phase.isEmpty ? '' : ' · $phase'}'
          '${label.isEmpty ? '' : ': $label'}';
    }
  }
  final usage = event['usage'];
  final last = '${event['last_tool_name'] ?? ''}'.trim();
  final uses = usage is Map ? usage['tool_uses'] : null;
  final ms = usage is Map ? usage['duration_ms'] : null;
  final parts = [
    if (last.isNotEmpty) last,
    if (uses is int) '$uses tool call${uses == 1 ? '' : 's'}',
    if (ms is int && ms >= 1000) '${(ms / 1000).round()}s',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
