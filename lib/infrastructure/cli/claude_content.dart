/// Claude's content blocks, read as the text the app shows.
///
/// The counterpart of the VS Code extension's content-type dispatch — the
/// component that switches on a block's `type`, and `toOutputContent`, which
/// flattens a tool's answer to text. Two jobs: which block types become text,
/// and what the CLI wraps round that text for the model, which has to come off
/// before a person reads it. Shared by the live feed and the session importer,
/// so a step says the same thing whichever way it reached the screen. The whole
/// map to the extension is in `docs/claude-rendering.md`.
library;

/// What a tool handed back, as the fold under its row shows it — and as an
/// imported session's step keeps it, since both read Claude's `tool_result`.
///
/// Verified against the real binary: a `tool_result` block carries `content`,
/// which is a plain string for the tools people actually watch (`Read` returns
/// the numbered lines, `Bash` returns its output, and a failure returns
/// `Exit code 1` and the error). Tools that answer with structured blocks —
/// images, some MCP servers, `ToolSearch` — send the array form instead, so
/// both are read, and anything that is neither is dropped rather than
/// stringified into `[{…}]`.
///
/// What the CLI wraps round the answer *for the model* is taken off, because
/// on screen it reads as the answer — see [_readable].
///
/// Returned **uncapped**: `AgentActivity.settled` is what caps it, and clipping
/// here as well counted the cut against the already-cut string — a 200KB read
/// came out saying 26 characters were dropped instead of 196,050.
String? claudeToolResult(Object? content) {
  final raw = switch (content) {
    final String text => text,
    final List<Object?> blocks => _blocksText(blocks),
    _ => null,
  };
  if (raw == null) return null;
  final text = _readable(raw.trim());
  return text.isEmpty ? null : text;
}

/// The text of a structured result: its text blocks, and the names a
/// `ToolSearch` answers with — `tool_reference` blocks, which carry no text of
/// their own and so left the row with nothing to open.
String _blocksText(List<Object?> blocks) =>
    [for (final block in blocks) ?_blockText(block)].join('\n');

String? _blockText(Object? block) => switch (block) {
  {'type': 'text', 'text': final String text} => text,
  {'type': 'tool_reference', 'tool_name': final String name} => name,
  _ => null,
};

/// [text] as the tool said it, without what the CLI adds for the model.
///
/// Three things, each counted across a month of this machine's sessions:
///
/// - **`<tool_use_error>`** round a failure (264 of them). The row already
///   says it failed; the tags only push the first words of why off the line.
/// - **`<system-reminder>`** blocks the CLI puts at either end of a result
///   (48) — "this memory may be outdated", a note on a file read. Only at the
///   ends: one in the *middle* is the file's own text (a file that quotes the
///   tag), and cutting it would edit what the tool read. A result that was
///   nothing but a reminder keeps its words, because then the reminder *is*
///   the answer — it is how an empty file is reported.
/// - **The CLI's refusal**, written to the model when a person said no (12):
///   "STOP what you are doing and wait for the user…" read, on screen, as the
///   app ordering the user about. Said instead as what happened.
String _readable(String text) {
  final said = _withoutReminders(text);
  final error = _toolUseError.firstMatch(said)?.group(1)?.trim();
  final answer = error ?? said;
  return _refusal(answer) ?? answer;
}

final _toolUseError = RegExp(r'^<tool_use_error>([\s\S]*)</tool_use_error>$');

const _reminderOpen = '<system-reminder>';

final _leadingReminder = RegExp(
  r'^<system-reminder>([\s\S]*?)</system-reminder>',
);

/// The last reminder block, when it is what the text ends on. The lookahead
/// stops the match reaching back past an earlier block's opening tag, which
/// would swallow everything between the two.
final _trailingReminder = RegExp(
  r'<system-reminder>((?:(?!<system-reminder>)[\s\S])*)</system-reminder>$',
);

String _withoutReminders(String text) {
  if (!text.contains(_reminderOpen)) return text;
  final (:rest, :notes) = _peelReminders(text);
  return rest.isNotEmpty ? rest : notes.where((n) => n.isNotEmpty).join('\n');
}

/// [text] with its edge reminders peeled off one at a time, and what each of
/// them said — the words a result made only of reminders falls back on.
({String rest, List<String> notes}) _peelReminders(String text) {
  final match =
      _leadingReminder.firstMatch(text) ?? _trailingReminder.firstMatch(text);
  if (match == null) return (rest: text, notes: const []);
  final peeled = _peelReminders(
    text.replaceRange(match.start, match.end, '').trim(),
  );
  return (
    rest: peeled.rest,
    notes: [(match.group(1) ?? '').trim(), ...peeled.notes],
  );
}

/// The sentence the CLI answers a refused tool call with, and the clause it
/// adds when the person gave a reason — both verbatim from Claude Code 2.1.
const _kRefused = "The user doesn't want to proceed with this tool use.";
const _kRefusedBecause =
    'The user provided the following reason for the rejection: ';

String? _refusal(String text) {
  if (!text.startsWith(_kRefused)) return null;
  final cut = text.indexOf(_kRefusedBecause);
  final reason = cut == -1
      ? ''
      : text.substring(cut + _kRefusedBecause.length).trim();
  return reason.isEmpty ? 'You said no to this.' : 'You said no: $reason';
}

/// What Claude Code writes into the person's turn when they stop it — once for
/// an answer, once for a tool that was running.
const _kInterruptNotes = {
  '[Request interrupted by user]',
  '[Request interrupted by user for tool use]',
};

/// Whether [text] is the CLI's note that the person stopped it, rather than
/// anything they typed.
///
/// It arrives in *their* turn, so read as written it goes in their bubble: an
/// imported session put these words in the user's mouth 52 times over a month
/// of this machine's sessions.
bool isClaudeInterruptNote(String text) =>
    _kInterruptNotes.contains(text.trim());
