import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/agent_turn_part.dart';

export '../../../infrastructure/cli/agent_turn_part.dart';

/// How many conversations keep a live agent session at once.
///
/// For Hermes one session is one `hermes acp` process, so this is a ceiling on
/// *processes*, not just memory. Flipping between a couple of chats — what
/// people actually do — costs nothing; past that the least recently used session
/// is closed, and that chat replays its history next time exactly as every chat
/// used to. Codex keeps only a thread id, so forgetting one costs it a replay
/// and nothing else; it honours the same cap so the two behave alike.
///
/// Deliberately small. A process this app fails to reap outlives it as an
/// orphan, and Windows has form here (`kill_group` and `pid_alive` were both
/// POSIX-only), so the number of processes in flight is worth keeping boring.
const int kMaxLiveAgentSessions = 5;

/// The folder the agent opens in when no project is picked, created on first
/// read. A starting point, not a fence — the agent may read and write outside it.
final agentWorkspaceDirProvider = Provider<Directory>((ref) {
  final dir = GridPaths.agentWorkspaceDir;
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
});

/// What one conversation's in-flight agent turn is doing right now: what it has
/// said and run so far in the order it happened, the pages it has cited, and the
/// to-do plan it is working through.
///
/// One object rather than three feeds because it is one turn's live state, and
/// keeping the three in step was the whole difficulty: they are reset together,
/// they belong to the same chat, and the bubble shows all three at once.
class AgentRun {
  const AgentRun({
    this.parts = const [],
    this.said = '',
    this.sources = const [],
    this.plan = const [],
    this.startedAt,
  });

  /// Nothing running (or nothing said yet) — what a chat with no turn reads as.
  static const empty = AgentRun();

  /// The turn as it happened: the passages the agent has written and the steps
  /// it has run, interleaved in order. See [TurnPart].
  final List<TurnPart> parts;

  /// How much of the agent's answer is already folded into [parts].
  ///
  /// Agents report their answer cumulatively, so this prefix is what tells the
  /// newest passage from the ones already placed — see [unsaidTail]. Held rather
  /// than recomputed from the text parts, because the two aren't the same string:
  /// the parts are trimmed for display, the prefix has to match what the agent
  /// itself sent.
  final String said;

  /// The shell commands and tool calls the agent has run this turn, each with
  /// its status — [parts] with the prose taken out.
  List<AgentActivity> get steps => stepsOf(parts);

  /// The web pages this turn has cited so far, deduplicated by url and kept in
  /// the order they were found. Pinned onto the answer when the turn lands, so
  /// the citations persist under the message.
  final List<WebSource> sources;

  /// The agent's live to-do list. Replaced wholesale each time the agent reports
  /// it — its `todo` tool sends the full list with each step's status, not a
  /// delta.
  final List<AgentPlanEntry> plan;

  /// When this turn began — t=0 for everything in [parts].
  ///
  /// It belongs here rather than beside the chat's send phase because this is
  /// the object the steps live in: anything measuring a step against the turn
  /// reads both ends of the subtraction off one value, and a second clock kept
  /// somewhere else could only ever start disagreeing with this one. Stamped by
  /// [AgentRuns.reset], which is the one call every agent turn makes before it
  /// does anything else. Null for a run nobody started that way — a step raised
  /// from outside a turn's stream, or a chat that has never run one.
  final DateTime? startedAt;

  AgentRun copyWith({
    List<TurnPart>? parts,
    String? said,
    List<WebSource>? sources,
    List<AgentPlanEntry>? plan,
    DateTime? startedAt,
  }) => AgentRun(
    parts: parts ?? this.parts,
    said: said ?? this.said,
    sources: sources ?? this.sources,
    plan: plan ?? this.plan,
    startedAt: startedAt ?? this.startedAt,
  );
}

/// The live feed of every agent turn in flight, keyed by the conversation it
/// belongs to.
///
/// **Keyed, not shared.** Agent turns run at the same time in different projects
/// (see `ChatSessionsState.runningAgentIds`), and one app-wide feed would show
/// each of those chats the other's work — and pin one chat's citations onto the
/// other's answer. The key is what keeps two live turns apart.
final agentRunsProvider = NotifierProvider<AgentRuns, Map<String, AgentRun>>(
  AgentRuns.new,
);

/// One chat's run — what its working bubble watches and its sender appends to.
/// Reads [AgentRun.empty] for a chat with nothing in flight.
final agentRunProvider = Provider.autoDispose.family<AgentRun, String>(
  (ref, chatId) => ref.watch(agentRunsProvider)[chatId] ?? AgentRun.empty,
);

class AgentRuns extends Notifier<Map<String, AgentRun>> {
  @override
  Map<String, AgentRun> build() => const {};

  /// Empty [chatId]'s feed so a starting turn never shows the previous one's.
  ///
  /// Called at the very top of an agent send, *before* the turn's awaited setup
  /// (pointing Hermes/Codex at the grid, opening the session): the chat flips to
  /// its "working" bubble the instant the send is committed, and that bubble
  /// reads this. Clearing it only once the stream reached the turn body — after
  /// that setup await — left the last turn's steps on screen for the whole wait.
  /// Also where the turn's clock starts ([AgentRun.startedAt]): this call is
  /// the first thing an agent send makes, before the setup it awaits, so it is
  /// the earliest honest answer to "when did this turn begin" — and the panel
  /// measures every step against it.
  void reset(String chatId) =>
      _write(chatId, AgentRun(startedAt: DateTime.now()));

  /// Drop [chatId] entirely — for a conversation that has been deleted, so its
  /// feed doesn't sit in memory for the rest of the run.
  void forget(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = Map.unmodifiable({
      for (final entry in state.entries)
        if (entry.key != chatId) entry.key: entry.value,
    });
  }

  /// Insert a step, or replace the existing one with the same id (a `started`
  /// step transitioning to `completed`).
  ///
  /// [answer] is the agent's whole reply as it stands — the senders have it in
  /// hand, and a step is exactly the boundary that closes a passage of it: what
  /// the agent had said before it ran this belongs *above* the row, not under
  /// the lot of them. Only a **new** step closes a passage; a result landing on
  /// a row that is already there changes its status where it sits, and nothing
  /// was said in between. Passing nothing (the refusal row, which is raised from
  /// outside a turn's stream) leaves the prose untouched.
  void upsertStep(String chatId, AgentActivity activity, {String answer = ''}) {
    final existing = _run(chatId).parts.indexWhere(
      (part) => part is TurnStep && part.step.id == activity.id,
    );
    if (existing == -1 && answer.isNotEmpty) say(chatId, answer);
    final parts = _run(chatId).parts;
    final next = [...parts];
    if (existing == -1) {
      next.add(TurnStep(activity.begunAt(DateTime.now())));
    } else {
      // The row's *original* stamp, not now: this event is the result landing
      // on a step that has been running for a while, and the transport builds a
      // fresh [AgentActivity] for it. Taking the new object's time would move
      // the step's start to the moment it ended, and the panel's clock — which
      // counts from that stamp — would read zero on everything that finished.
      final began = (parts[existing] as TurnStep).step.startedAt;
      next[existing] = TurnStep(
        began == null ? activity : activity.begunAt(began),
      );
    }
    _write(chatId, _run(chatId).copyWith(parts: List.unmodifiable(next)));
  }

  /// Close off everything of [answer] the timeline hasn't placed yet as the
  /// turn's newest passage.
  ///
  /// Called when a step arrives (the passage before it has ended) and once more
  /// as the turn lands, so the closing words are in the timeline before it is
  /// pinned onto the message. Text is only ever *added* here — the streaming
  /// bubble draws the open passage straight from the send phase, so this runs a
  /// handful of times a turn rather than once per token.
  void say(String chatId, String answer) {
    final run = _run(chatId);
    if (answer.isEmpty || answer == run.said) return;
    final tail = unsaidTail(said: run.said, answer: answer);
    _write(
      chatId,
      run.copyWith(
        said: answer,
        parts: tail.isEmpty
            ? run.parts
            : List.unmodifiable([...run.parts, TurnText(tail)]),
      ),
    );
  }

  /// Append [sources], skipping any url already collected this turn.
  void addSources(String chatId, List<WebSource> sources) {
    final run = _run(chatId);
    final seen = {for (final s in run.sources) s.url};
    final fresh = [
      for (final s in sources)
        if (seen.add(s.url)) s,
    ];
    if (fresh.isEmpty) return;
    _write(
      chatId,
      run.copyWith(sources: List.unmodifiable([...run.sources, ...fresh])),
    );
  }

  /// Replace the plan with the agent's latest full to-do list.
  void setPlan(String chatId, List<AgentPlanEntry> entries) =>
      _write(chatId, _run(chatId).copyWith(plan: List.unmodifiable(entries)));

  AgentRun _run(String chatId) => state[chatId] ?? AgentRun.empty;

  void _write(String chatId, AgentRun run) =>
      state = Map.unmodifiable({...state, chatId: run});
}

/// The single status that stands for a whole run of [steps] — for the one-line
/// summary a long, folded run shows instead of every row.
///
/// [AgentActivityStatus.running] wins while any step is still going (the run is
/// live, so the summary spins); otherwise [AgentActivityStatus.failed] if any
/// failed (a settled run with a problem to surface); otherwise
/// [AgentActivityStatus.unknown] if any step never reported, since a summary
/// may not vouch for a run holding a step nobody can vouch for; otherwise
/// [AgentActivityStatus.done]. Empty reads as done.
AgentActivityStatus aggregateActivityStatus(List<AgentActivity> steps) {
  if (steps.any((s) => s.status == AgentActivityStatus.running)) {
    return AgentActivityStatus.running;
  }
  if (steps.any((s) => s.status == AgentActivityStatus.failed)) {
    return AgentActivityStatus.failed;
  }
  if (steps.any((s) => s.status == AgentActivityStatus.unknown)) {
    return AgentActivityStatus.unknown;
  }
  return AgentActivityStatus.done;
}

/// The length past which a run of steps gets a summary line it can fold into.
///
/// A short run reads at a glance and is left alone; a long one — an agent that
/// opens three dozen files before it says a word — would otherwise push the
/// answer, the plan and the "Thinking…" line off the screen entirely.
///
/// There used to be a `foldedActivitySteps` beside this, which kept the latest
/// five rows on screen *while folded*. It was written when folding was the only
/// way to keep a live run from swallowing the answer, and it is gone now that
/// folding shows one row and a long run folds itself the moment it finishes: a
/// fold that leaves five rows behind reads as a fold that didn't work.
///
/// **Three, measured.** At five this almost never fired: across the 8,172 runs
/// in this machine's imported Claude history the median run is *one* step, 94%
/// are three or fewer, and only 3% ran past five — so the fold was a feature
/// nobody saw. Three is where it starts paying: it folds 7% of runs and takes
/// 13,922 drawn rows down to 10,688, while a pair of steps — the shape of
/// nearly every run — still reads at a glance, which is what this limit is for.
///
/// It only changes *finished* turns. A live run is expanded regardless
/// (`_expanded ?? live` in `AgentStepList`), so nothing folds under the user
/// while they are watching it work.
const int kFoldedStepLimit = 3;
