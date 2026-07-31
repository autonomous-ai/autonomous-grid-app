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

/// The live activity feed of the in-flight agent run — the shell commands and
/// tool calls the agent runs, newest appended last. The "agent is working"
/// bubble watches this; `HermesChatSender` clears it at the start of each send
/// and upserts each step as Hermes reports it over ACP.
final agentActivityProvider =
    NotifierProvider<AgentActivityLog, List<AgentActivity>>(
      AgentActivityLog.new,
    );

class AgentActivityLog extends Notifier<List<AgentActivity>> {
  @override
  List<AgentActivity> build() => const [];

  void clear() => state = const [];

  /// Insert a new step, or replace the existing one with the same id (a
  /// `started` step transitioning to `completed`).
  void upsert(AgentActivity activity) {
    final index = state.indexWhere((step) => step.id == activity.id);
    if (index == -1) {
      state = [...state, activity];
      return;
    }
    final next = [...state];
    next[index] = activity;
    state = List.unmodifiable(next);
  }
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

/// The web pages the in-flight agent run has cited so far, deduplicated by url
/// and kept in the order they were found. The "agent is working" bubble shows
/// them live; `HermesChatSender` clears it at the start of each send, adds each
/// batch as Hermes reports it, and pins the final list onto the answer so the
/// citations persist under the message.
final agentSourcesProvider = NotifierProvider<AgentSourcesLog, List<WebSource>>(
  AgentSourcesLog.new,
);

class AgentSourcesLog extends Notifier<List<WebSource>> {
  @override
  List<WebSource> build() => const [];

  void clear() => state = const [];

  /// Append [sources], skipping any url already collected this turn.
  void addAll(List<WebSource> sources) {
    final seen = {for (final s in state) s.url};
    final fresh = [
      for (final s in sources)
        if (seen.add(s.url)) s,
    ];
    if (fresh.isEmpty) return;
    state = List.unmodifiable([...state, ...fresh]);
  }
}

/// The agent's live to-do plan for the in-flight run. Unlike the sources feed,
/// this is **replaced** wholesale each time Hermes reports it — its `todo` tool
/// sends the full list (with each step's status), not a delta. The "agent is
/// working" bubble shows it live so the user sees which step it's on; and
/// `HermesChatSender` clears it at the start of each send and pins the final
/// plan onto the answer.
final agentPlanProvider = NotifierProvider<AgentPlanLog, List<AgentPlanEntry>>(
  AgentPlanLog.new,
);

class AgentPlanLog extends Notifier<List<AgentPlanEntry>> {
  @override
  List<AgentPlanEntry> build() => const [];

  void clear() => state = const [];

  /// Replace the plan with the agent's latest full to-do list.
  void replace(List<AgentPlanEntry> entries) =>
      state = List.unmodifiable(entries);
}

/// Empty the shared agent feed — the running turn's steps, cited sources and
/// plan — so a starting turn never shows the previous one's (or another chat's).
///
/// Called at the very top of an agent send, *before* the turn's awaited setup
/// (pointing Hermes/Codex at the grid, opening the session): the chat flips to
/// its "working" bubble the instant the send is committed, and that bubble reads
/// this one app-wide feed. Clearing it only once the stream reached the turn body
/// — after that setup await — left the last turn's steps on screen for the whole
/// wait. Clearing here, synchronously as the stream is first listened, closes
/// that window.
void resetAgentFeed(Ref ref) {
  ref.read(agentActivityProvider.notifier).clear();
  ref.read(agentSourcesProvider.notifier).clear();
  ref.read(agentPlanProvider.notifier).clear();
}
