import 'dart:convert';

import '../../../playground/logic/chat_message.dart';
import 'parsed_session.dart';

/// The line types worth reading in a rollout. `event_msg` is deliberately not
/// among them: it is a *second* account of the same conversation (every
/// `agent_message` event restates a `response_item` that is already on the
/// stream), so reading both would double the transcript.
const _kSessionMeta = 'session_meta';
const _kTurnContext = 'turn_context';
const _kResponseItem = 'response_item';

/// Reads a Codex rollout file into a transcript, or null when there is no
/// conversation in it.
///
/// The file is JSON Lines under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// Its first line is a `session_meta` header carrying the id and the folder;
/// after that the conversation arrives as `response_item` lines — messages,
/// tool calls, and the model's encrypted reasoning.
///
/// Pure and line-independent, for the same reason as the Claude parser: one
/// unreadable line costs one message, never the session.
///
/// [preferredTitle] is the thread name Codex keeps in `session_index.jsonl` —
/// the name the user last saw in Codex's own list. Nothing in the rollout
/// itself is a title, so where that name exists it is simply better than
/// anything derivable here.
ParsedSession? parseCodexSession({
  required String fallbackSessionId,
  required List<String> lines,
  String? preferredTitle,
}) {
  final drafts = <TurnDraft>[];
  // Steps waiting on their outcome, by `call_id` — a Codex call and its output
  // are two separate items on the stream, often far apart.
  final pending = <String, StepDraft>{};
  String? sessionId;
  String? workdir;
  String? model;
  DateTime? firstAt;
  DateTime? lastAt;
  var toolCalls = 0;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;

    final payload = decoded['payload'];
    if (payload is! Map<String, dynamic>) continue;
    final at = _parseStamp(decoded['timestamp']);

    switch (decoded['type']) {
      case _kSessionMeta:
        // The header, and the only line that names the session. A compaction
        // writes a second one mid-file, so the *first* wins — that is the id
        // the thread has been known by all along.
        sessionId ??= _stringOrNull(payload['session_id']);
        workdir ??= _stringOrNull(payload['cwd']);
        firstAt ??= _parseStamp(payload['timestamp']) ?? at;
      case _kTurnContext:
        // Written once per turn, and the only place the model is named. The
        // last one wins: a session can switch model part way through, and what
        // the transcript should say is what answered it in the end.
        model = _stringOrNull(payload['model']) ?? model;
        workdir ??= _stringOrNull(payload['cwd']);
      case _kResponseItem:
        if (at != null) {
          firstAt ??= at;
          lastAt = at;
        }
        final draft = _itemToDraft(
          payload,
          model: model,
          pending: pending,
          sentAt: at,
        );
        if (draft == null) continue;
        toolCalls += draft.items.whereType<StepDraft>().length;
        drafts.add(draft);
    }
  }

  final (messages: merged, clipped: truncated) = finishDrafts(
    mergeDrafts(drafts),
    agentId: ImportedAgent.codex.id,
  );
  if (merged.isEmpty) return null;
  final started = firstAt ?? lastAt;
  if (started == null) return null;

  return ParsedSession(
    agent: ImportedAgent.codex,
    sessionId: sessionId ?? fallbackSessionId,
    title: preferredTitle?.trim().isNotEmpty == true
        ? preferredTitle!.trim()
        : titleFromMessages(merged),
    messages: merged,
    startedAt: started,
    updatedAt: lastAt ?? started,
    workdir: workdir,
    model: model,
    toolCalls: toolCalls,
    truncatedMessages: truncated,
  );
}

/// A `response_item` as one turn's worth of draft, or null when it carries
/// nothing the user should read.
///
/// One draft per item, even for a single step: consecutive assistant drafts are
/// merged afterwards ([mergeDrafts]), which keeps the item order without this
/// having to track which turn is open.
TurnDraft? _itemToDraft(
  Map<String, dynamic> payload, {
  required String? model,
  required Map<String, StepDraft> pending,
  required DateTime? sentAt,
}) {
  switch (payload['type']) {
    case 'message':
      final role = payload['role'];
      // The system prompt and the app's own briefing, in the user's file but
      // never in the user's voice.
      if (role == 'developer' || role == 'system') return null;
      final text = _messageText(payload['content']);
      if (text.isEmpty) return null;
      return role == 'user'
          ? (TurnDraft(ChatRole.user, sentAt: sentAt)..say(text))
          : (TurnDraft(ChatRole.assistant, model: model, sentAt: sentAt)
              ..say(text));

    case 'function_call':
      return _stepDraft(
        payload,
        model: model,
        pending: pending,
        sentAt: sentAt,
        tool: _stringOrNull(payload['name']) ?? 'tool',
        request: _requestText(payload['arguments']),
      );

    case 'custom_tool_call':
      return _stepDraft(
        payload,
        model: model,
        pending: pending,
        sentAt: sentAt,
        tool: _stringOrNull(payload['name']) ?? 'tool',
        request: _stringOrNull(payload['input']),
      );

    case 'tool_search_call':
      final arguments = payload['arguments'];
      return _stepDraft(
        payload,
        model: model,
        pending: pending,
        sentAt: sentAt,
        tool: 'tool search',
        request: arguments is Map<String, dynamic>
            ? _stringOrNull(arguments['query'])
            : null,
      );

    // The other half of a call. It carries no turn of its own — it fills in the
    // step already on the timeline.
    case 'function_call_output':
    case 'custom_tool_call_output':
    case 'tool_search_output':
      final step = pending.remove(_stringOrNull(payload['call_id']));
      step?.result = _stringOrNull(payload['output']);
      return null;

    // `reasoning` is an encrypted blob with nothing readable in it.
    default:
      return null;
  }
}

/// A one-step draft, registered so its output can find it later.
TurnDraft _stepDraft(
  Map<String, dynamic> payload, {
  required String? model,
  required Map<String, StepDraft> pending,
  required DateTime? sentAt,
  required String tool,
  required String? request,
}) {
  final id =
      _stringOrNull(payload['call_id']) ?? _stringOrNull(payload['id']) ?? '';
  final step = StepDraft(
    id: id,
    tool: tool,
    kind: stepKindFor(tool),
    request: request,
  );
  if (id.isNotEmpty) pending[id] = step;
  return TurnDraft(ChatRole.assistant, model: model, sentAt: sentAt)..ran(step);
}

/// The readable text of a message's content blocks.
///
/// Codex names them by direction — `input_text` on the way in, `output_text` on
/// the way out — and both are prose. Anything else (an image, a file part) is
/// skipped rather than guessed at.
String _messageText(Object? content) {
  if (content is String) return stripInjectedContext(content);
  if (content is! List) return '';
  final parts = <String>[];
  for (final block in content) {
    if (block is! Map<String, dynamic>) continue;
    final type = block['type'];
    if (type != 'input_text' && type != 'output_text' && type != 'text') {
      continue;
    }
    final text = _stringOrNull(block['text']);
    if (text == null) continue;
    final cleaned = stripInjectedContext(text);
    if (cleaned.isNotEmpty) parts.add(cleaned);
  }
  return parts.join('\n\n').trim();
}

/// What was asked of the tool, as text a person can read.
///
/// The arguments arrive as a JSON *string*. The named field wins where the call
/// has one — `cmd` is the command, and a command is what the row is about —
/// and anything else is re-indented rather than shown as one packed line, since
/// the row can be opened to read it.
String? _requestText(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return raw;
  }
  if (decoded is! Map<String, dynamic>) return raw;
  for (final key in const ['cmd', 'command', 'file_path', 'path', 'query']) {
    final value = decoded[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is List && value.isNotEmpty) return value.join(' ');
  }
  return const JsonEncoder.withIndent('  ').convert(decoded);
}

String? _stringOrNull(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw : null;

DateTime? _parseStamp(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
