import 'dart:convert';

/// One structured event from `codex exec --json`, which prints its agent loop to
/// stdout as JSONL. Modelled as a sealed hierarchy so callers switch
/// exhaustively instead of string-matching a raw map.
///
/// The wire shapes (verified empirically against codex-cli 0.141):
/// - `{"type":"thread.started","thread_id":"…"}`
/// - `{"type":"turn.started"}` / `{"type":"turn.completed","usage":{…}}`
/// - `{"type":"turn.failed","error":{"message":"…"}}`
/// - `{"type":"error","message":"…"}` (transient reconnects + the final error)
/// - `{"type":"item.{started,completed}","item":{"type":"command_execution",
///   "command":"…","aggregated_output":"…","exit_code":0,"status":"…"}}`
/// - `…"item":{"type":"mcp_tool_call","tool":"…","status":"…","error":{…}}`
/// - `…"item":{"type":"agent_message","text":"…"}}` (the final answer)
/// - `…"item":{"type":"error","message":"…"}}`
/// - `…"item":{"type":"reasoning","text":"…"}}` (verbose; not surfaced)
sealed class CodexEvent {
  const CodexEvent();
}

/// The agent session opened; [threadId] identifies it for a later `codex exec
/// resume` (session continuity is a follow-up — see `CodexChatSender`).
class CodexThreadStarted extends CodexEvent {
  const CodexThreadStarted(this.threadId);
  final String threadId;
}

/// A completed assistant message — the answer text to show the user. The final
/// such item in a turn carries the reply.
class CodexAgentMessage extends CodexEvent {
  const CodexAgentMessage(this.text);
  final String text;
}

/// A step the agent is running (a shell command or a tool call). Emitted for
/// both the start and the completion of the underlying item so the UI can show
/// a live "running → done/failed" activity feed of what the agent is doing.
class CodexActivityUpdate extends CodexEvent {
  const CodexActivityUpdate(this.activity);
  final CodexActivity activity;
}

/// A non-fatal item-level error (e.g. the model-metadata fallback warning). Kept
/// distinct from a turn failure so the UI doesn't treat a warning as a crash.
class CodexItemError extends CodexEvent {
  const CodexItemError(this.message);
  final String message;
}

/// The turn began — the agent started working.
class CodexTurnStarted extends CodexEvent {
  const CodexTurnStarted();
}

/// The turn finished successfully.
class CodexTurnCompleted extends CodexEvent {
  const CodexTurnCompleted();
}

/// The turn failed; [message] is the raw reason (humanized before display).
class CodexTurnFailed extends CodexEvent {
  const CodexTurnFailed(this.message);
  final String message;
}

/// A top-level stream error (transient reconnect or the final failure line).
class CodexStreamError extends CodexEvent {
  const CodexStreamError(this.message);
  final String message;
}

/// A recognised envelope we deliberately ignore (reasoning, in-progress
/// agent_message, other item types). Distinct from an unparseable line so the
/// parser stays total.
class CodexUnknownEvent extends CodexEvent {
  const CodexUnknownEvent();
}

/// What kind of step the agent is running.
enum CodexActivityKind { command, tool }

/// Lifecycle of one agent step, driving its live status indicator.
enum CodexActivityStatus { running, done, failed }

/// One agent step in the live activity feed. Keyed by [id] so a `started` event
/// and its later `completed` event update the same row rather than duplicating.
class CodexActivity {
  const CodexActivity({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
  });

  final String id;
  final CodexActivityKind kind;

  /// Short human label — the shell command, or the tool name.
  final String label;
  final CodexActivityStatus status;
}

/// Parses one JSONL line from `codex exec --json` into a [CodexEvent]. Returns
/// null for blank or non-JSON lines (codex also logs plain text to stderr, and
/// interleaves the odd banner) so the caller can skip them without crashing.
CodexEvent? parseCodexEvent(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;

  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  switch (decoded['type']) {
    case 'thread.started':
      return CodexThreadStarted(_string(decoded['thread_id']));
    case 'turn.started':
      return const CodexTurnStarted();
    case 'turn.completed':
      return const CodexTurnCompleted();
    case 'turn.failed':
      return CodexTurnFailed(
        _messageOf(decoded['error']) ?? 'Agent turn failed.',
      );
    case 'error':
      return CodexStreamError(_string(decoded['message'], fallback: 'error'));
    case 'item.started':
    case 'item.updated':
    case 'item.completed':
      return _item(
        decoded['item'],
        completed: decoded['type'] == 'item.completed',
      );
    default:
      return const CodexUnknownEvent();
  }
}

CodexEvent _item(Object? raw, {required bool completed}) {
  if (raw is! Map<String, dynamic>) return const CodexUnknownEvent();
  switch (raw['type']) {
    case 'command_execution':
      return CodexActivityUpdate(
        CodexActivity(
          id: _string(raw['id']),
          kind: CodexActivityKind.command,
          label: _commandLabel(_string(raw['command'])),
          status: _activityStatus(raw),
        ),
      );
    case 'mcp_tool_call':
      return CodexActivityUpdate(
        CodexActivity(
          id: _string(raw['id']),
          kind: CodexActivityKind.tool,
          label: _string(raw['tool'], fallback: 'tool'),
          status: _activityStatus(raw),
        ),
      );
    case 'agent_message':
      // Only the completed item carries the final answer text.
      return completed
          ? CodexAgentMessage(_string(raw['text']))
          : const CodexUnknownEvent();
    case 'error':
      return completed
          ? CodexItemError(_string(raw['message'], fallback: 'error'))
          : const CodexUnknownEvent();
    default:
      // reasoning, file_change, patch_apply, todo_list, web_search — not
      // surfaced yet (read-only agent produces few; reasoning is verbose).
      return const CodexUnknownEvent();
  }
}

/// Maps an item's `status` (+ `exit_code`/`error`) to a feed status. A completed
/// command with a non-zero exit, or a tool call that carried an error, is a
/// failure even though its lifecycle `status` reads "completed".
CodexActivityStatus _activityStatus(Map<String, dynamic> item) {
  if (item['status'] == 'failed') return CodexActivityStatus.failed;
  if (item['status'] == 'completed') {
    final code = item['exit_code'];
    if (code is int && code != 0) return CodexActivityStatus.failed;
    if (item['error'] != null) return CodexActivityStatus.failed;
    return CodexActivityStatus.done;
  }
  return CodexActivityStatus.running;
}

/// Turns a raw shell command into a short label: unwraps the `/bin/sh -lc '…'`
/// codex wraps commands in, collapses whitespace, and truncates.
String _commandLabel(String raw) {
  var cmd = raw;
  final inner = RegExp(r"-lc '(.*)'\s*$", dotAll: true).firstMatch(raw);
  if (inner != null) cmd = inner.group(1) ?? raw;
  cmd = cmd.trim().replaceAll(RegExp(r'\s+'), ' ');
  return cmd.length > 80 ? '${cmd.substring(0, 79)}…' : cmd;
}

String? _messageOf(Object? raw) =>
    raw is Map<String, dynamic> ? _string(raw['message']) : null;

String _string(Object? raw, {String fallback = ''}) =>
    raw is String ? raw : fallback;
