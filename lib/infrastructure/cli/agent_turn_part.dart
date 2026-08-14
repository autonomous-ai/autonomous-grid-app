import 'agent_event.dart';

/// One slice of an agent's turn, in the order it happened — a passage it wrote,
/// or a step it ran.
///
/// A turn is not "an answer, with some tool calls off to one side". The agent
/// says a sentence, runs a command, reads what came back, says the next
/// sentence. Holding the two in one ordered list is what lets the chat replay
/// that sequence; keeping them in two lists could only ever draw the whole
/// answer and then every step underneath it, which reads as an agent that wrote
/// first and worked afterwards — the reverse of what actually happened.
///
/// Lives beside [AgentActivity] because the agent transports produce both, and a
/// part is only ever a step plus where it sat in the telling.
sealed class TurnPart {
  const TurnPart();
}

/// A passage the agent wrote — one unbroken run of prose between two steps.
class TurnText extends TurnPart {
  const TurnText(this.text);

  final String text;
}

/// A step the agent ran, kept where it happened. The same [AgentActivity] the
/// live feed draws, so a finished turn shows the rows the user watched go by
/// rather than a second, tidier account of them.
class TurnStep extends TurnPart {
  const TurnStep(this.step);

  final AgentActivity step;
}

/// The steps of [parts], in order — what the stall check, the fold and the
/// status summary all read, none of which care where the prose sat.
List<AgentActivity> stepsOf(List<TurnPart> parts) => [
  for (final part in parts)
    if (part is TurnStep) part.step,
];

/// Whether [parts] holds any step at all. A turn that ran nothing has no
/// sequence worth recording — its timeline would be the answer and nothing else,
/// which is what [ChatMessage.text] already says.
bool hasSteps(List<TurnPart> parts) => parts.any((part) => part is TurnStep);

/// [parts] with nothing left running — what a turn that has *ended* looks like.
///
/// A step is only ever moved off "running" by the event that reports its
/// outcome, and a turn can end before that arrives: Stop is pressed while a
/// command is going, the agent's process dies, the stream breaks. Saved as it
/// stood, that row reloads as a spinner turning forever inside a transcript from
/// last week — a chat that looks like it is still working on something nothing
/// is working on.
///
/// It settles as [AgentActivityStatus.unknown] — not failed, and not done. The
/// tool never reported back, and *that* is the whole fact: a red mark would
/// accuse a step that very likely worked (Hermes doesn't always send a closing
/// update), and a tick would vouch for one that may have been killed mid-run.
List<TurnPart> settledParts(List<TurnPart> parts) => [
  for (final part in parts)
    if (part case TurnStep(
      :final step,
    ) when step.status == AgentActivityStatus.running)
      TurnStep(step.settled(status: AgentActivityStatus.unknown))
    else
      part,
];

/// What of [answer] the timeline hasn't shown yet, given the [said] prefix
/// already folded into it.
///
/// Every agent reports its answer *cumulatively* — the whole reply so far, not
/// the newest words — so the passage that belongs after the last step is the
/// remainder. Trimmed, because the join between blocks (`\n\n` for three of the
/// four agents) would otherwise open each passage with blank lines.
///
/// The fallback matters as much as the rule: an answer that doesn't continue
/// [said] is one the agent **replaced**, which Claude Code does on its closing
/// `result` line (it reports the final passage alone, not the whole turn). Read
/// as a continuation that would strand the last passage; read as a replacement
/// of everything it would drop the passages that came before the steps. Taking
/// it as the tail alone is right in both readings — the earlier passages are
/// already parts, and this is the newest one.
///
/// The prefix is matched with trailing whitespace ignored, because the two
/// strings compared here have been through different hands: a passage is closed
/// with the answer exactly as it streamed (`"…the config.\n\n"`, paragraph break
/// and all), while the same answer reaches the landing **trimmed** — every
/// sender ends on `answer.toString().trim()`. Compared literally, the trimmed
/// one doesn't continue the untrimmed one, the fallback reads it as a fresh
/// passage, and a turn that said one thing and then ran a command showed that
/// sentence twice.
String unsaidTail({required String said, required String answer}) {
  if (answer.isEmpty) return '';
  final anchor = said.trimRight();
  if (anchor.isEmpty) return answer.trim();
  if (answer.startsWith(anchor)) return answer.substring(anchor.length).trim();
  // Same passage, differently edged — an answer that opened with a blank line
  // loses it to the same trim, so it no longer *starts with* what was said even
  // though it says exactly that and nothing more.
  if (answer.trim() == anchor.trim()) return '';
  return answer.trim();
}

/// A part as it is stored with the conversation. Steps carry their own four
/// fields rather than a nested object: a row is one flat thing on screen and one
/// flat thing on disk.
Map<String, Object?> turnPartToJson(TurnPart part) => switch (part) {
  TurnText(:final text) => {'kind': 'text', 'text': text},
  TurnStep(:final step) => {
    'kind': 'step',
    'id': step.id,
    // `tool` is the *activity* kind, which picks the icon — it was written under
    // that name before a step carried the tool's own name, and renaming it now
    // would silently blank the icon on every chat already on disk. The tool's
    // real name goes under `name`.
    'tool': step.kind.name,
    if (step.tool != null) 'name': step.tool,
    // Capped like the result, and for the same reason: a *thinking* row carries
    // the model's whole reasoning here — several thousand characters a step, in
    // a file rewritten whole on every turn.
    'label': _stored(step.label),
    'status': step.status.name,
    // Written only when the transport carried them, so a lane that reports no
    // payload (and every chat saved before this existed) keeps the shape it had.
    //
    // The request is capped like everything else here. It was left uncapped on
    // the reasoning that a request is small — true of a command line, false of
    // the one tool whose arguments carry a whole file: a `Write` step stored
    // 4KB of file body per row, and the reader's own cap then cut the *note*
    // off the end and replaced "196050 more characters" with "26".
    if (step.request != null) 'request': _stored(step.request!),
    if (step.result != null) 'result': _stored(step.result!),
    if (step.parent != null) 'parent': step.parent,
  },
};

/// How much of a step's *result* is kept on disk — far less than the fold shows
/// while the turn is live.
///
/// The two aren't the same question. On screen the output is what the user is
/// reading right now; on disk it is one row of one step of a turn from last
/// week, inside a file that is rewritten whole every time the chat is spoken in.
/// A turn like the one this was built for runs twenty-odd commands, and at the
/// live cap that is half a megabyte of shell output re-encoded on every
/// following turn — to show something nobody scrolls back for.
///
/// The request is *not* capped this way: a command line or an arguments object
/// is small, and it is the half worth having later ("what did it actually run?").
const int kStoredResultLimit = 800;

/// [text] cut to [kStoredResultLimit], saying so plainly.
///
/// The note carries no number, unlike the live cut: this text has usually been
/// clipped once already, so counting what is missing from *it* would understate
/// what was missing from the output.
String _stored(String text) {
  if (text.length <= kStoredResultLimit) return text;
  // Same surrogate rule as [clipToolPayload]: never cut a character in half.
  final unit = text.codeUnitAt(kStoredResultLimit - 1);
  final end = (unit >= 0xD800 && unit <= 0xDBFF)
      ? kStoredResultLimit - 1
      : kStoredResultLimit;
  return '${text.substring(0, end)}\n\n… trimmed to keep the saved chat small';
}

/// Rebuilds a stored part, or null when the entry carries nothing usable — a
/// blank passage, a step with no label, a `kind` a later build writes. Lenient
/// like every other reader here (§6): one odd entry drops out of the timeline
/// instead of taking the whole conversation down with it.
TurnPart? turnPartFromJson(Object? raw) {
  if (raw is! Map) return null;
  switch (raw['kind']) {
    case 'text':
      final text = raw['text'];
      if (text is! String || text.trim().isEmpty) return null;
      return TurnText(text);
    case 'step':
      final label = raw['label'];
      if (label is! String || label.trim().isEmpty) return null;
      return TurnStep(
        AgentActivity(
          id: '${raw['id'] ?? label}',
          kind: _kindByName(raw['tool']),
          label: label,
          status: _statusByName(raw['status']),
          tool: raw['name'] is String ? raw['name'] as String : null,
          request: clipToolPayload(
            raw['request'] is String ? raw['request'] as String : null,
          ),
          result: clipToolPayload(
            raw['result'] is String ? raw['result'] as String : null,
          ),
          parent: raw['parent'] is String ? raw['parent'] as String : null,
        ),
      );
    default:
      return null;
  }
}

/// An unknown tool name reads as the generic kind — it only picks an icon, and a
/// wrench says less than claiming a step ran a shell command that it didn't.
AgentActivityKind _kindByName(Object? raw) {
  for (final kind in AgentActivityKind.values) {
    if (kind.name == raw) return kind;
  }
  return AgentActivityKind.tool;
}

/// A stored step is settled by definition — the turn it belonged to ended.
///
/// So `running` is never read back as running, however plainly it is written:
/// the turn is over, and a row that says otherwise is a spinner turning forever
/// inside a transcript from last week. It reads as
/// [AgentActivityStatus.unknown], the same verdict [settledParts] gives on the
/// way out — the step never reported, and neither a tick nor a red mark is a
/// thing the app is entitled to say about it.
///
/// The check is here, on the reading side, as well as at [settledParts] on the
/// writing side: chats saved by a build that wrote `running` are already on
/// disk, and only this end can heal those.
///
/// An unreadable status reads as done — a step we can't place is one that
/// happened, not one that broke.
AgentActivityStatus _statusByName(Object? raw) {
  if (raw == AgentActivityStatus.running.name) {
    return AgentActivityStatus.unknown;
  }
  for (final status in AgentActivityStatus.values) {
    if (status.name == raw) return status;
  }
  return AgentActivityStatus.done;
}
