import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/agent_event.dart';

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

/// What one conversation's in-flight agent turn is doing right now: the steps it
/// is running (newest last), the pages it has cited, and the to-do plan it is
/// working through.
///
/// One object rather than three feeds because it is one turn's live state, and
/// keeping the three in step was the whole difficulty: they are reset together,
/// they belong to the same chat, and the bubble shows all three at once.
class AgentRun {
  const AgentRun({
    this.steps = const [],
    this.sources = const [],
    this.plan = const [],
  });

  /// Nothing running (or nothing said yet) — what a chat with no turn reads as.
  static const empty = AgentRun();

  /// The shell commands and tool calls the agent has run this turn, each with
  /// its status.
  final List<AgentActivity> steps;

  /// The web pages this turn has cited so far, deduplicated by url and kept in
  /// the order they were found. Pinned onto the answer when the turn lands, so
  /// the citations persist under the message.
  final List<WebSource> sources;

  /// The agent's live to-do list. Replaced wholesale each time the agent reports
  /// it — its `todo` tool sends the full list with each step's status, not a
  /// delta.
  final List<AgentPlanEntry> plan;

  AgentRun copyWith({
    List<AgentActivity>? steps,
    List<WebSource>? sources,
    List<AgentPlanEntry>? plan,
  }) => AgentRun(
    steps: steps ?? this.steps,
    sources: sources ?? this.sources,
    plan: plan ?? this.plan,
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
  void reset(String chatId) => _write(chatId, AgentRun.empty);

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
  void upsertStep(String chatId, AgentActivity activity) {
    final steps = _run(chatId).steps;
    final index = steps.indexWhere((step) => step.id == activity.id);
    final next = [...steps];
    if (index == -1) {
      next.add(activity);
    } else {
      next[index] = activity;
    }
    _write(chatId, _run(chatId).copyWith(steps: List.unmodifiable(next)));
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
/// [AgentActivityStatus.done]. Empty reads as done.
AgentActivityStatus aggregateActivityStatus(List<AgentActivity> steps) {
  if (steps.any((s) => s.status == AgentActivityStatus.running)) {
    return AgentActivityStatus.running;
  }
  if (steps.any((s) => s.status == AgentActivityStatus.failed)) {
    return AgentActivityStatus.failed;
  }
  return AgentActivityStatus.done;
}

/// How many steps a folded run shows at once, and the length past which a run
/// folds at all. A short run reads at a glance; a long one — an agent that opens
/// three dozen files before it says a word — would otherwise push the answer,
/// the plan and the "Thinking…" line off the screen entirely.
const int kFoldedStepLimit = 5;

/// The rows a folded run shows: what is running *now*, filled up to
/// [kFoldedStepLimit] with the steps that ran most recently, in the order they
/// ran.
///
/// Both halves are needed. Running-only goes blank between tool calls, so a
/// thinking agent looks like it has done nothing; newest-only can bury a slow
/// command under five quick reads that started after it and finished first. The
/// cap is what makes it a summary: an agent may have thirty reads in flight at
/// once, and thirty spinning rows say no more than five do.
List<AgentActivity> foldedActivitySteps(List<AgentActivity> steps) {
  if (steps.length <= kFoldedStepLimit) return steps;
  final picked = <int>{};
  // Newest first, so what fills the remaining room is the latest work.
  void take(bool Function(AgentActivity step) wanted) {
    for (var i = steps.length - 1; i >= 0; i--) {
      if (picked.length == kFoldedStepLimit) return;
      if (wanted(steps[i])) picked.add(i);
    }
  }

  take((step) => step.status == AgentActivityStatus.running);
  take((_) => true);
  final order = picked.toList()..sort();
  return List.unmodifiable([for (final i in order) steps[i]]);
}
