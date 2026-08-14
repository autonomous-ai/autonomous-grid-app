/// Where a conversation can pick an agent session back up.
///
/// Claude Code and Codex each hold the conversation on their own side and take
/// an id to resume it with (`claude --resume <id>`, `codex exec resume <id>`).
/// The app has always known that id — `AgentSessionSlot` learns it from the
/// first turn — but only in memory, so quitting the app cost every chat its
/// session and replayed the whole transcript into a fresh one on the next
/// message. Written down beside the chat, the same conversation carries on.
///
/// It is also what makes an *imported* chat more than a record: a session this
/// app never started can be continued, because the id the other tool uses is
/// the id this one resumes.
///
/// Lives in the infrastructure layer rather than in either feature because both
/// sides need it and neither owns it: the chat feature persists it with the
/// conversation, the agents feature reads it when planning a turn.
class AgentResumePoint {
  const AgentResumePoint({
    required this.agent,
    required this.sessionId,
    required this.seen,
    this.workdir,
  });

  /// The `AgentTool` id that owns the session (`claude`, `codex`).
  ///
  /// A bare string for the same reason `Project.agent` is one: an id a later
  /// build no longer ships has to read as "no resume point" rather than throw,
  /// and resuming is the one thing that must fail *safely* — a wrong id doesn't
  /// error, it silently answers from a stranger's conversation.
  final String agent;

  /// The agent's own id for the session.
  final String sessionId;

  /// How many of the conversation's messages the agent already holds.
  ///
  /// The next turn sends only what comes after this mark. Replaying the whole
  /// transcript into a session that already has it would not merely waste
  /// context — the agent would read its own past answers as new instructions.
  final int seen;

  /// The folder the session ran in, or null when it ran nowhere in particular.
  ///
  /// A session resumed somewhere else is a session reading different files, so
  /// a point is only adopted when this matches the turn's own working folder —
  /// see `AgentSessionSlots.planTurn`.
  final String? workdir;

  /// Whether this point may be used for a turn running [thisAgent] in
  /// [thisWorkdir].
  ///
  /// Both halves have to match. The agent is obvious — Codex cannot resume a
  /// Claude session id. The folder is the half that looks optional and isn't:
  /// the id would resume perfectly well from anywhere, and the agent would
  /// carry on editing the files it remembers rather than the ones it is now
  /// pointed at.
  bool matches({required String thisAgent, required String? thisWorkdir}) =>
      agent == thisAgent && workdir == thisWorkdir;

  Map<String, Object?> toJson() => {
    'agent': agent,
    'sessionId': sessionId,
    'seen': seen,
    if (workdir != null) 'workdir': workdir,
  };

  /// Reads a stored point, or null when there isn't a usable one.
  ///
  /// Lenient like the rest of the conversation file: a hand-edited or
  /// half-written point reads as "this chat has no session to resume", which
  /// costs a replay — the same thing that happens for every chat saved before
  /// this field existed.
  static AgentResumePoint? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final agent = raw['agent'];
    final sessionId = raw['sessionId'];
    if (agent is! String || agent.isEmpty) return null;
    if (sessionId is! String || sessionId.isEmpty) return null;
    final seen = raw['seen'];
    final workdir = raw['workdir'];
    return AgentResumePoint(
      agent: agent,
      sessionId: sessionId,
      // A missing or negative count reads as zero: the agent holds nothing, so
      // the next turn replays the transcript. Wrong in the safe direction — the
      // opposite guess would drop messages the agent never saw.
      seen: seen is num && seen >= 0 ? seen.toInt() : 0,
      workdir: workdir is String && workdir.isNotEmpty ? workdir : null,
    );
  }
}
