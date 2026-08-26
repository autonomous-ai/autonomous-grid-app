import '../../../infrastructure/cli/agent_resume_point.dart';
import '../../playground/logic/chat_message.dart';
import 'agent_prompt.dart';
import 'agent_providers.dart';

/// One conversation's live agent session: the id to resume it with, and how much
/// of the chat the agent has already been given.
class AgentSessionSlot {
  AgentSessionSlot({required this.key, required this.seen});

  /// `networkId|model|conversationId|workdir` — a change in any of these means a
  /// *new* session, not a continuation of this one (a different grid, model,
  /// conversation or project folder).
  final String key;

  /// The agent's own id for the session, known once the first turn reports it.
  /// Null until then, which forces the next turn to start fresh.
  String? sessionId;

  /// How many of the conversation's messages the agent has been given. A longer
  /// history next time is a continuation (and everything past this mark goes
  /// with the next turn); anything else restarts.
  int seen;

  /// How full the model's context was at the end of this session's last turn,
  /// in tokens. Zero until a turn has reported one.
  ///
  /// **On the slot, not per model.** A slot is one conversation, on one model,
  /// in one folder — exactly the scope a session's context has. Filed per model
  /// instead, a long chat sitting at 80% would follow the user into a chat they
  /// just opened and have its first turn summarize a session holding nothing.
  /// Here it resets by construction: a new conversation is a new slot, and a new
  /// slot starts at zero.
  int usedTokens = 0;

  /// What the pictures this session has been shown cost on top of [usedTokens],
  /// estimated by the app because [usedTokens] leaves them out — see
  /// `claudeMediaTokens` for the measurement behind that.
  ///
  /// Accumulated across the session's turns, because that is how pictures
  /// accumulate in a context, and reset wherever [usedTokens] is: a summary
  /// replaces them with words, and a new session never saw them.
  int mediaTokens = 0;

  /// What this session is really carrying: what the last turn reported, plus
  /// what the app estimates that report left out.
  ///
  /// The one figure to compare against a ceiling. Reading [usedTokens] alone is
  /// how a chat walked into a 400 at 236545 tokens while every check in the app
  /// believed it held 40593.
  int get contextTokens => usedTokens + mediaTokens;
}

/// What one turn should send, and how.
typedef AgentTurnPlan = ({
  /// The prompt: what the agent hasn't seen on a continuation, the whole history
  /// on a fresh start.
  String text,

  /// The session to resume, or null to start a new one.
  String? resumeSessionId,

  /// Whether this is a fresh session — the moment to hand over one-off context
  /// like the project's own instructions.
  bool freshStart,

  /// The slot this turn belongs to, for the sender to write the session id and
  /// the seen count back onto.
  AgentSessionSlot slot,
});

/// The per-conversation session bookkeeping shared by the agents that run **one
/// process per turn** — Codex and Claude Code.
///
/// Both hold the conversation on their own side and take a session id to resume,
/// so all a sender has to remember is that id and how far the agent has been
/// told. That was the same fifty lines twice, and the two copies had already
/// begun to drift in their comments.
///
/// Hermes is deliberately not here: its slot holds a live ACP *process*, so
/// evicting one has to close it. Folding that in would put a lifecycle hook into
/// a class whose whole point is that it owns nothing.
class AgentSessionSlots {
  /// Remembered sessions by conversation, least recently used **first** — the
  /// order they get dropped in. A slot is an id and a counter, not a process, so
  /// forgetting one costs only a replay; the cap is [kMaxLiveAgentSessions] all
  /// the same, so every sender behaves alike.
  final _live = <String, AgentSessionSlot>{};

  /// Decide between resuming this conversation's session and starting fresh.
  ///
  /// [key] is what makes two turns the same session — see [AgentSessionSlot.key].
  ///
  /// [adopt] is a session written down beside the conversation, for the case
  /// this class could never answer on its own: there is nothing in memory,
  /// because the app has only just started — or because the chat was imported
  /// from the tool that opened the session in the first place. The caller has
  /// already checked it belongs to this agent and this folder
  /// ([AgentResumePoint.matches]); what is decided here is only whether it
  /// still fits the transcript.
  AgentTurnPlan planTurn({
    required String key,
    required String? conversationId,
    required List<ChatMessage> history,
    AgentResumePoint? adopt,
  }) {
    // A conversation gets one slot; the key still decides whether what's in it
    // can be resumed.
    final id = conversationId ?? '';
    final live = _live[id];
    final continues =
        live != null &&
        live.key == key &&
        live.sessionId != null &&
        history.length > live.seen;

    if (continues) {
      _touch(id);
      // Everything appended since the agent's last turn, not just the newest
      // message — see [buildAgentPrompt]. A picture turn and a scheduled task's
      // result both reach the chat without an agent turn behind them.
      final unseen = history.sublist(live.seen);
      live.seen = history.length;
      return (
        text: buildAgentPrompt(unseen),
        resumeSessionId: live.sessionId,
        freshStart: false,
        slot: live,
      );
    }

    // Nothing in memory for this chat, but something on disk. Picking it up
    // beats starting over: the agent still holds the whole conversation, so the
    // alternative is replaying a transcript it already has — which costs the
    // context the replay fills and, on a long chat, is the difference between
    // carrying on and starting again.
    //
    // Only when there is no live slot at all. A slot whose key no longer
    // matches means the user changed something this session can't follow, and
    // reaching past it to an older, written-down id would resume the very
    // session that mismatch just retired.
    if (live == null &&
        adopt != null &&
        // The mark has to sit inside the transcript, with something after it to
        // send. Equal means the agent has seen everything and there is nothing
        // to say; greater means the two have diverged — messages were deleted
        // here — and only a replay can put that right.
        adopt.seen < history.length) {
      _evictToFit();
      final adopted = AgentSessionSlot(key: key, seen: history.length)
        ..sessionId = adopt.sessionId;
      _live[id] = adopted;
      return (
        text: buildAgentPrompt(history.sublist(adopt.seen)),
        resumeSessionId: adopt.sessionId,
        // Not a fresh *session* — but it is the first turn this app has sent
        // into it, so it is the moment the project's standing brief is handed
        // over. That brief has never been in this session: an imported one was
        // run by another tool entirely, and one from a previous launch was
        // given the brief as it stood then.
        freshStart: true,
        slot: adopted,
      );
    }

    _live.remove(id);
    _evictToFit();
    final fresh = AgentSessionSlot(key: key, seen: history.length);
    _live[id] = fresh;
    return (
      text: buildAgentPrompt(history),
      resumeSessionId: null,
      freshStart: true,
      slot: fresh,
    );
  }

  /// Drop least-recently-used slots until there is room for one more.
  void _evictToFit() {
    while (_live.length >= kMaxLiveAgentSessions) {
      _live.remove(_live.keys.first);
    }
  }

  /// Drop this conversation's slot, so the next turn starts a session and
  /// replays the chat into it.
  ///
  /// For the case where the agent's own copy is gone — a session folder cleared
  /// under a running app — and resuming can only keep failing. Forgetting costs
  /// a replay, which is what a fresh slot does anyway; keeping it costs every
  /// later message in that chat.
  void forget(String? conversationId) => _live.remove(conversationId ?? '');

  /// Move [id] to the most-recently-used end — see [_live].
  void _touch(String id) {
    final entry = _live.remove(id);
    if (entry != null) _live[id] = entry;
  }
}
