/// How the app learns which conversation an interactive agent CLI is holding.
///
/// The three agents answer this three genuinely different ways, and the
/// differences are not incidental:
///
/// - **Claude Code** is *told*. The app makes up a v4 UUID, passes it as
///   `--session-id`, and the CLI holds the conversation under it. Nothing has to
///   be found afterwards, so there is no race to lose.
/// - **Codex** cannot be told one at all. Its id can only be read back off the
///   rollout file it writes — on its *first turn*, not at start-up — so the app
///   has to know what was on disk beforehand to tell the new file from the rest.
/// - **Hermes** cannot be told one either, but it can be *renamed*: `--resume`
///   takes a title as readily as an id, so one discovery is enough to pin a name
///   the app chose and never look again.
///
/// What is the same across all three is the part that kept being a bug, which is
/// why this interface exists rather than three private helpers:
///
/// 1. **A deadline.** A watch that cannot answer has to stop asking. Codex's
///    used to run for the life of the session — once two rollouts shared a
///    working directory `pickCodexSession` could never choose between them, and
///    the app kept listing `~/.codex/sessions` every three seconds to be told so
///    again.
/// 2. **Ambiguity means null, never a guess.** Resuming the wrong conversation
///    is silent and unrecoverable: the agent carries on editing files it
///    remembers rather than the ones it is now pointed at, and the work it was
///    actually asked about is simply gone from view.
/// 3. **Liveness.** The chat that asked can close, restart, or switch agent
///    while the answer is still being looked for, and an id that arrives after
///    that must be dropped rather than written over whatever replaced it.
///
/// Layering: this deliberately names no type from `features/`. The launch handle
/// (`AgentSession`) is assembled by the caller out of [mint] and whatever id
/// survived [holds], which keeps the dependency pointing one way.
library;

/// Where an agent's session ids come from, for one agent.
abstract interface class AgentSessionSource {
  /// Whether [sessionId] still names a conversation this agent can resume on
  /// this computer.
  ///
  /// The id a chat remembers is only worth passing while the agent still has the
  /// conversation behind it; `--resume` on one that is gone fails in ways that
  /// read to the user as the agent having forgotten them.
  Future<bool> holds(String sessionId);

  /// A brand-new id to hand the CLI at launch, or null for an agent that cannot
  /// be told what to call its session.
  ///
  /// Non-null is the easy case and the one worth having: an id the app chose is
  /// an id it never has to go looking for.
  String? mint();

  /// Begins watching for the session this launch is about to create.
  ///
  /// **Called before the CLI is spawned.** For an agent whose id can only be
  /// discovered, the only way to tell its new session apart from everything
  /// already on disk is to have looked first — so the sampling has to happen on
  /// this side of the spawn even though the answer arrives long after it.
  ///
  /// [resuming] says whether this launch already carries an id. Whether that
  /// makes the watch unnecessary is the source's own call, and the three
  /// genuinely disagree: Codex has nothing left to learn once it is resuming,
  /// while Hermes watches either way, because its resume can quietly miss and
  /// the replacement session is exactly what the watch would find.
  Future<AgentSessionWatch> watch({
    required String chatId,
    required String workdir,
    required bool resuming,
  });
}

/// One launch's outstanding question: which session did that CLI start?
abstract interface class AgentSessionWatch {
  /// The id to remember for this chat, or null when it cannot be told for
  /// certain.
  ///
  /// [keepWaiting] is the caller's answer to "is this still the terminal you
  /// asked about" — false once the chat has closed it, restarted it, or handed
  /// it to another agent. [deadline] is the wall clock this gives up at
  /// regardless.
  ///
  /// Implementations must return null rather than their best guess. A caller
  /// that receives null starts a fresh conversation next time, which costs the
  /// user their history; a caller that receives the wrong id loses their work.
  Future<String?> settle({
    required bool Function() keepWaiting,
    required Duration deadline,
  });
}

/// How long a watch looks before giving up.
///
/// Generous, because Codex writes its rollout on the first turn and the user may
/// take minutes to type it. Finite, because the alternative is what this
/// replaced: a directory listing every three seconds for as long as the chat
/// stayed open, answering a question that had already become unanswerable.
const Duration kAgentSessionWatchWindow = Duration(minutes: 30);

/// A watch that already knows the answer — the agent whose id the app chose.
///
/// Settles immediately, including with null: a launch that resumed an existing
/// session has nothing new to learn, and saying so at once keeps the caller from
/// holding a watcher open for an answer that will never change.
class SettledSessionWatch implements AgentSessionWatch {
  const SettledSessionWatch(this.id);

  final String? id;

  @override
  Future<String?> settle({
    required bool Function() keepWaiting,
    required Duration deadline,
  }) async => id;
}
