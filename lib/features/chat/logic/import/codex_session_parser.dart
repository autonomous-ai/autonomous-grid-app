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
  final messages = <ChatMessage>[];
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
        final message = _itemToMessage(payload, model: model);
        if (message == null) continue;
        if (message.isStep) toolCalls++;
        messages.add(
          message.role == ChatRole.user
              ? ChatMessage(role: ChatRole.user, text: message.text)
              : ChatMessage(
                  role: ChatRole.assistant,
                  text: message.text,
                  agent: ImportedAgent.codex.id,
                  model: message.model,
                ),
        );
    }
  }

  // Whole turns, not the lines they were assembled from — see [clipTurns].
  final (messages: merged, clipped: truncated) = clipTurns(
    mergeTurns(messages),
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

/// A `response_item` as one transcript message, or null when it carries nothing
/// the user should read.
///
/// [isStep] marks the ones that were a tool call rather than something said, so
/// the caller can count them without inspecting the text it just built.
({ChatRole role, String text, String? model, bool isStep})? _itemToMessage(
  Map<String, dynamic> payload, {
  required String? model,
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
          ? (role: ChatRole.user, text: text, model: null, isStep: false)
          : (role: ChatRole.assistant, text: text, model: model, isStep: false);

    case 'function_call':
      return (
        role: ChatRole.assistant,
        text: foldedToolCall(
          tool: _stringOrNull(payload['name']) ?? 'tool',
          detail: _argumentsDetail(payload['arguments']),
        ),
        model: model,
        isStep: true,
      );

    case 'custom_tool_call':
      return (
        role: ChatRole.assistant,
        text: foldedToolCall(
          tool: _stringOrNull(payload['name']) ?? 'tool',
          detail: _stringOrNull(payload['input']),
        ),
        model: model,
        isStep: true,
      );

    case 'tool_search_call':
      final arguments = payload['arguments'];
      return (
        role: ChatRole.assistant,
        text: foldedToolCall(
          tool: 'tool search',
          detail: arguments is Map<String, dynamic>
              ? _stringOrNull(arguments['query'])
              : null,
        ),
        model: model,
        isStep: true,
      );

    // `function_call_output`, `tool_search_output` and `reasoning` are all
    // dropped: the first two are the tool output this import doesn't carry (see
    // [foldedToolCall]), and reasoning is an encrypted blob with nothing
    // readable in it.
    default:
      return null;
  }
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

/// The one field of a call's arguments worth showing on a folded line.
///
/// The arguments arrive as a JSON *string*, so a call that can't be decoded
/// falls back to the raw text — clipped like everything else, and still more
/// use than showing nothing.
String? _argumentsDetail(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return raw;
  }
  if (decoded is! Map<String, dynamic>) return raw;
  for (final key in const [
    'cmd',
    'command',
    'file_path',
    'path',
    'query',
    'pattern',
    'url',
    'description',
  ]) {
    final value = decoded[key];
    if (value is String && value.trim().isNotEmpty) return value;
    // `exec_command` sometimes carries the command as its argv list.
    if (value is List && value.isNotEmpty) return value.join(' ');
  }
  for (final value in decoded.values) {
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return raw;
}

String? _stringOrNull(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw : null;

DateTime? _parseStamp(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
