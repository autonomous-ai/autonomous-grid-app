import 'dart:convert';

import '../../../playground/logic/chat_message.dart';
import 'parsed_session.dart';

/// The line types that carry conversation. Everything else on the stream —
/// `queue-operation`, `last-prompt`, `attachment`, `file-history-snapshot` —
/// describes the CLI's own state rather than what was said.
const _kUser = 'user';
const _kAssistant = 'assistant';
const _kTitle = 'ai-title';

/// Reads a Claude Code session file into a transcript, or null when there is no
/// conversation in it.
///
/// The file is JSON Lines under `~/.claude/projects/<cwd-slug>/<id>.jsonl`, one
/// event per line, appended as the session runs. Only two of its line types are
/// the conversation — `user` and `assistant`; the rest is the CLI's own
/// bookkeeping (queued prompts, file snapshots, the title it picked) and is
/// either mined for one fact or skipped.
///
/// Pure, and tolerant by construction: every line is independent, so a line
/// that won't parse is dropped rather than failing the session. These files are
/// written by a tool that ships weekly and owes this app no compatibility — a
/// shape we don't recognise has to cost one message, never the import.
///
/// [sessionId] comes from the file *name* rather than the content: the id is
/// what `claude --resume` takes, and the name is the one place it is guaranteed
/// to be even in a file whose every line we failed to read.
///
/// [preferredTitle] stands in when the file holds no `ai-title` line — the name
/// the scan already read off the head of the file, rather than a second guess
/// at the same thing.
ParsedSession? parseClaudeSession({
  required String sessionId,
  required List<String> lines,
  String? preferredTitle,
}) {
  final drafts = <TurnDraft>[];
  // Steps waiting on their outcome, by the tool call's own id. Claude answers a
  // `tool_use` with a `tool_result` in the *next* message, so a step is always
  // built before the thing that says how it went.
  final pending = <String, StepDraft>{};
  String? title;
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

    final type = decoded['type'];
    if (type == _kTitle) {
      // The name Claude Code gave the session. Written repeatedly as the
      // session grows and occasionally in two languages; the last one wins,
      // because it is the one the user last saw in that tool's own list.
      final named = decoded['aiTitle'];
      if (named is String && named.trim().isNotEmpty) title = named.trim();
      continue;
    }
    if (type != _kUser && type != _kAssistant) continue;

    // A subagent's private transcript, interleaved into the same file. It is a
    // second conversation — one the user never saw and never spoke in — and
    // folding it in would read as the assistant answering questions nobody
    // asked.
    if (decoded['isSidechain'] == true) continue;
    // Context the CLI injected as if the user had typed it.
    if (decoded['isMeta'] == true) continue;

    workdir ??= _stringOrNull(decoded['cwd']);
    final at = _parseStamp(decoded['timestamp']);
    if (at != null) {
      firstAt ??= at;
      lastAt = at;
    }

    final message = decoded['message'];
    if (message is! Map<String, dynamic>) continue;
    final content = message['content'];

    if (type == _kUser) {
      // A user line carries two unrelated things: what the person typed, and
      // the output of every tool the agent just ran. The results go to the
      // steps waiting on them; only the typing is a turn.
      _settleResults(content, pending);
      final text = _userText(content);
      if (text.isEmpty) continue;
      drafts.add(TurnDraft(ChatRole.user)..say(text));
      continue;
    }

    final turnModel = _stringOrNull(message['model']);
    if (turnModel != null) model = turnModel;
    final draft = TurnDraft(ChatRole.assistant, model: turnModel);
    _fillAssistant(draft, content, pending);
    if (draft.isEmpty) continue;
    toolCalls += draft.items.whereType<StepDraft>().length;
    drafts.add(draft);
  }

  final (messages: merged, clipped: truncated) = finishDrafts(
    mergeDrafts(drafts),
    agentId: ImportedAgent.claude.id,
  );
  if (merged.isEmpty) return null;

  // No usable stamp anywhere in the file — every line was unreadable, or an
  // older build wrote none. The caller's file dates stand in; guessing "now"
  // here would file a chat from March under today.
  final started = firstAt ?? lastAt;
  if (started == null) return null;

  return ParsedSession(
    agent: ImportedAgent.claude,
    sessionId: sessionId,
    title: title ?? _fallbackTitle(preferredTitle, merged),
    messages: merged,
    startedAt: started,
    updatedAt: lastAt ?? started,
    workdir: workdir,
    model: model,
    toolCalls: toolCalls,
    truncatedMessages: truncated,
  );
}

/// The name to use when the file never carried an `ai-title`: what the scan
/// read off its head, else the app's own rule for naming a chat by its first
/// message.
String _fallbackTitle(String? preferred, List<ChatMessage> messages) {
  final trimmed = preferred?.trim() ?? '';
  return trimmed.isEmpty ? titleFromMessages(messages) : trimmed;
}

/// What the user actually said on a `user` line.
///
/// Two things wear that role and are not the user talking, and both have to go
/// or the transcript doubles:
///
/// - **`tool_result` blocks.** Every tool the agent runs comes back as a `user`
///   line carrying the output. In this file 63 of the 73 `user` lines were
///   these. Imported as written, a session reads as the user pasting command
///   output at themselves between every question.
/// - **Injected context blocks.** `<system-reminder>`, and — when the session
///   was driven from an IDE — `<ide_opened_file>` and `<ide_selection>`. They
///   are addressed to the model, they are not what was typed, and some are long
///   enough to bury the actual question. See [stripInjectedContext].
String _userText(Object? content) {
  if (content is String) return stripInjectedContext(content);
  if (content is! List) return '';
  final parts = <String>[];
  for (final block in content) {
    if (block is! Map<String, dynamic>) continue;
    // Deliberately not `tool_result`, and not `image`: an image block holds
    // base64 bytes that would have to be written out as a file to mean
    // anything, which an import doesn't do — see the note on the import screen.
    if (block['type'] != 'text') continue;
    final text = _stringOrNull(block['text']);
    if (text == null) continue;
    final cleaned = stripInjectedContext(text);
    if (cleaned.isNotEmpty) parts.add(cleaned);
  }
  return parts.join('\n\n').trim();
}

/// Fill [draft] from an assistant line's content blocks, in order.
///
/// Order is kept because it is the whole point: the agent says a sentence, runs
/// a command, reads what came back, says the next sentence — and reading it in
/// that order is the only way the transcript explains itself.
///
/// `thinking` blocks are dropped. They are the model's private reasoning, they
/// are the longest thing in the file, and neither tool shows them by default in
/// its own UI.
void _fillAssistant(
  TurnDraft draft,
  Object? content,
  Map<String, StepDraft> pending,
) {
  if (content is String) {
    draft.say(content);
    return;
  }
  if (content is! List) return;
  for (final block in content) {
    if (block is! Map<String, dynamic>) continue;
    switch (block['type']) {
      case 'text':
        final text = _stringOrNull(block['text']);
        if (text != null) draft.say(text);
      case 'tool_use':
        final id = _stringOrNull(block['id']) ?? '';
        final tool = _stringOrNull(block['name']) ?? 'tool';
        final step = StepDraft(
          id: id,
          tool: tool,
          kind: stepKindFor(tool),
          request: _request(block['input']),
        );
        draft.ran(step);
        // Keyless steps can still be shown; they just never learn how they
        // went, which [StepDraft.build] reports as `unknown` rather than
        // guessing.
        if (id.isNotEmpty) pending[id] = step;
    }
  }
}

/// Hand each `tool_result` in [content] to the step it belongs to.
void _settleResults(Object? content, Map<String, StepDraft> pending) {
  if (content is! List) return;
  for (final block in content) {
    if (block is! Map<String, dynamic>) continue;
    if (block['type'] != 'tool_result') continue;
    final step = pending.remove(_stringOrNull(block['tool_use_id']));
    if (step == null) continue;
    step.result = _resultText(block['content']);
    // Written by the CLI as a real bool on some builds and the string "False"
    // on others, so only an explicit truth counts as a failure.
    step.failed = block['is_error'] == true || block['is_error'] == 'True';
  }
}

/// A tool result's content as text. It arrives as a plain string, or as the
/// same block list a message uses.
String? _resultText(Object? content) {
  if (content is String) return content.trim().isEmpty ? null : content;
  if (content is! List) return null;
  final parts = <String>[];
  for (final block in content) {
    if (block is Map<String, dynamic> && block['type'] == 'text') {
      final text = _stringOrNull(block['text']);
      if (text != null) parts.add(text);
    }
  }
  return parts.isEmpty ? null : parts.join('\n');
}

/// What the agent asked the tool to do, as text a person can read.
///
/// The named field where the tool has one — the command, the path, the pattern
/// — because that is the request. Everything else falls back to the arguments
/// as JSON, which is what the field is documented to hold and is still readable
/// when the row is opened.
String? _request(Object? input) {
  if (input is! Map<String, dynamic>) return null;
  for (final key in const ['command', 'file_path', 'path', 'pattern', 'url']) {
    final value = input[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return input.isEmpty
      ? null
      : const JsonEncoder.withIndent('  ').convert(input);
}

String? _stringOrNull(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw : null;

/// A line's stamp as local time, or null when it hasn't got a readable one.
DateTime? _parseStamp(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
