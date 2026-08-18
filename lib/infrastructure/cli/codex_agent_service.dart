import 'agent_event.dart';

/// One thing to show from a running Codex turn — the same shapes the Chat tab
/// already renders for Hermes ([AgentActivity], [WebSource], [AgentPlanEntry], a
/// chunk of the answer), so every agent feeds the one activity/plan/sources feed.
///
/// Codex speaks its own protocol, not ACP, so it gets its own thin envelope —
/// but the payloads are the shared, agent-neutral ones, so nothing downstream
/// has to know which agent produced them. What fills these in is
/// [CodexAppServerService]; the shapes live apart from it because the chat reads
/// them and must not depend on the transport underneath.
sealed class CodexEvent {
  const CodexEvent();
}

/// Codex's id for the conversation, seen once when the thread opens. The sender
/// keeps it so the next turn resumes that thread instead of starting the
/// conversation over.
class CodexThreadStarted extends CodexEvent {
  const CodexThreadStarted(this.threadId);
  final String threadId;
}

/// A shell command, web look-up or tool call Codex ran while answering.
class CodexActivityEvent extends CodexEvent {
  const CodexActivityEvent(this.activity);
  final AgentActivity activity;
}

/// The answer so far — the full assembled text, not a delta, so the sender
/// replaces rather than appends (Codex reports each message whole).
class CodexMessageEvent extends CodexEvent {
  const CodexMessageEvent(this.text);
  final String text;
}

/// Codex's to-do list as it stands now, replacing the previous one wholesale.
class CodexPlanEvent extends CodexEvent {
  const CodexPlanEvent(this.entries);
  final List<AgentPlanEntry> entries;
}

/// What happened to one file in a landed `apply_patch`.
enum CodexFileChangeKind { add, update, delete }

/// One file Codex touched this turn: its (absolute) path and what happened to it.
///
/// Only a freshly *added* file can be shown downstream with an honest
/// before/after (see [codexAddedPaths]) — the transport now carries a unified
/// diff per file, but nothing here reads it yet.
typedef CodexFileChange = ({String path, CodexFileChangeKind kind});

/// The files Codex created, edited or removed in one `apply_patch`, surfaced
/// once the patch has landed so the chat can offer to open what it just wrote.
class CodexFileChangeEvent extends CodexEvent {
  const CodexFileChangeEvent(this.changes);
  final List<CodexFileChange> changes;
}

/// The turn failed for good — the model stream broke, auth was rejected, the
/// grid didn't answer. Carries Codex's own last words, humanized by the sender.
class CodexTurnFailed extends CodexEvent {
  const CodexTurnFailed(this.message);
  final String message;
}

/// Codex ended the turn by itself — it was done, not cut off. The chat needs the
/// difference: a turn that finished normally with a to-do step left unticked is
/// the model's own sloppy bookkeeping, not work it abandoned (see
/// [agentTurnStalled]). Sent on `turn/completed`, and on a clean exit for a
/// build that spells that event differently.
class CodexTurnCompleted extends CodexEvent {
  const CodexTurnCompleted();
}

/// Thrown when a Codex turn can't even start (the binary won't launch).
class CodexException implements Exception {
  const CodexException(this.message, {this.retryable = true});

  final String message;

  /// Whether sending again could plausibly work. False for a machine that isn't
  /// set up: the same send fails the same way, so a retry only wastes the user's.
  final bool retryable;

  @override
  String toString() => 'CodexException: $message';
}

/// A single running Codex turn: its parsed events, a future that completes when
/// the process exits, a kill switch, and the way back to a turn that stopped to
/// ask. Unlike Hermes's persistent ACP session, each Codex turn is its own
/// server process; continuity comes from resuming the thread, not from keeping
/// the process alive.
class CodexRun {
  const CodexRun({
    required this.events,
    required this.done,
    required this.kill,
    required this.answerPermission,
  });

  final Stream<CodexEvent> events;
  final Future<void> done;
  final void Function() kill;

  /// Answer a [CodexPermissionRequested] by the id it carried: an option id to
  /// allow, or null to refuse. The turn is stopped until this is called, and
  /// answering one twice does nothing.
  final void Function(Object id, String? optionId) answerPermission;
}

/// Drives Codex as a chat agent. Behind an interface so the sender is tested
/// against a fake that replays scripted turns.
abstract interface class CodexService {
  /// Run one turn. [resumeThreadId] continues an earlier conversation; null
  /// starts a fresh one. [workdir] is the folder the turn opens in, and
  /// [approval] is how much it may do there before it stops and asks.
  ///
  /// [config] carries the grid and model as `-c` overrides for this run alone
  /// (see `codexGridOverrides`) and [environment] the key they name — so a turn
  /// answers on the app's grid without the user's own `~/.codex/config.toml`
  /// being rewritten. Throws [CodexException] if the process won't start.
  CodexRun run({
    required String workdir,
    required String prompt,
    required List<String> config,
    required Map<String, String> environment,
    required AgentApprovalMode approval,
    String? resumeThreadId,
  });
}

/// The paths of files Codex freshly *created* in [changes]. Only an add can be
/// shown with an honest diff and undo — Codex reports an update's path but not
/// its old contents — so the chat records just these for its open/undo bar; an
/// update or delete is left out rather than given a diff or undo it can't back.
List<String> codexAddedPaths(List<CodexFileChange> changes) => [
  for (final change in changes)
    if (change.kind == CodexFileChangeKind.add) change.path,
];

/// Codex has stopped, mid-turn, and won't go on until this is answered.
///
/// The same [AgentPermission] Hermes raises over ACP and Claude Code raises over
/// its control channel, so one card and one policy serve all three.
class CodexPermissionRequested extends CodexEvent {
  const CodexPermissionRequested(this.request);
  final AgentPermission request;
}
