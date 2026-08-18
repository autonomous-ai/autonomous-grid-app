/// A sub-agent's work, read off the flat step list the transport produced.
///
/// Claude Code runs a sub-agent **inside the parent's stream**: every line it
/// produces carries `parent_tool_use_id`, which the parser keeps as
/// [AgentActivity.parent]. So the steps are all there — what is missing is that
/// they arrive *interleaved*. An agent that fans out to three sub-agents at once
/// emits A1, B1, A2, C1, B2, … in the order the three of them happen to answer,
/// and drawn in that order they read as one agent doing unrelated things, since
/// every nested row is stepped in by the same amount whoever ran it.
///
/// Everything here is pure and works off the list alone, so what the transcript
/// shows can be reasoned about without a running agent.
library;

import '../../../infrastructure/cli/agent_event.dart';
import 'agent_step_label.dart';

/// One sub-agent's run: the row that started it, and what it has done since.
class SubRun {
  const SubRun({
    required this.parentId,
    required this.total,
    required this.active,
    required this.failed,
    required this.settled,
  });

  /// The `Agent`/`Task` step that delegated this work — the row the group hangs
  /// under.
  final String parentId;

  /// How many steps the sub-agent has run so far.
  final int total;

  /// The step it is on right now, or null when nothing of its own is running.
  ///
  /// The *last* running one, for the reason the feed's own status line picks
  /// that way: a sub-agent can hold several steps open at once, and the newest
  /// is the one actually happening.
  final AgentActivity? active;

  /// How many of its steps failed. Reported as a count rather than as a colour
  /// on the row — a retry that found the next path is an ordinary way to work,
  /// and painting it red turns a turn that went fine into a wall of alarm (the
  /// call [AgentActivity] already documents for the step glyph).
  final int failed;

  /// Whether the delegating row itself has reported back. False while the
  /// sub-agent is still working, which is what decides whether the group is
  /// drawn open or folded to its summary.
  final bool settled;
}

/// The sub-agent runs in [steps], keyed by the id of the step that started each.
///
/// Only parents that are actually in [steps] get an entry: a folded run can
/// begin mid-group, and a summary hanging off a row nobody can see would count
/// steps the screen does not show.
Map<String, SubRun> subRunsOf(List<AgentActivity> steps) {
  final parents = <String, AgentActivity>{
    for (final step in steps)
      if (!step.isNested) step.id: step,
  };
  if (parents.isEmpty) return const {};
  final total = <String, int>{};
  final failed = <String, int>{};
  final active = <String, AgentActivity>{};
  for (final step in steps) {
    final parent = step.parent;
    if (parent == null || !parents.containsKey(parent)) continue;
    total[parent] = (total[parent] ?? 0) + 1;
    if (step.status == AgentActivityStatus.failed) {
      failed[parent] = (failed[parent] ?? 0) + 1;
    }
    // Last one wins: see [SubRun.active].
    if (step.status == AgentActivityStatus.running) active[parent] = step;
  }
  return {
    for (final entry in total.entries)
      entry.key: SubRun(
        parentId: entry.key,
        total: entry.value,
        active: active[entry.key],
        failed: failed[entry.key] ?? 0,
        settled:
            parents[entry.key]!.status != AgentActivityStatus.running &&
            active[entry.key] == null,
      ),
  };
}

/// [steps] with each sub-agent's work gathered under the row that started it.
///
/// The parents keep the order they ran in, and so do the children within one
/// group — nothing is sorted, only moved next to what it belongs to. That is
/// enough to tell two concurrent sub-agents apart, because their rows stop
/// alternating.
///
/// A child whose parent is not in [steps] stays exactly where it was: a folded
/// run may start halfway through a group, and hoisting an orphan to the top
/// would claim it happened before work that came first.
///
/// Returns [steps] itself when there is nothing nested, so the ordinary turn —
/// which is most of them — pays nothing for this and the view's identity check
/// still short-circuits.
List<AgentActivity> orderedBySubRun(List<AgentActivity> steps) {
  final parents = <String>{
    for (final step in steps)
      if (!step.isNested) step.id,
  };
  final children = <String, List<AgentActivity>>{};
  for (final step in steps) {
    final parent = step.parent;
    if (parent == null || !parents.contains(parent)) continue;
    (children[parent] ??= <AgentActivity>[]).add(step);
  }
  if (children.isEmpty) return steps;
  final ordered = <AgentActivity>[];
  for (final step in steps) {
    // Placed under its parent below, not here.
    if (step.isNested && parents.contains(step.parent)) continue;
    ordered.add(step);
    final own = children[step.id];
    if (own != null) ordered.addAll(own);
  }
  return ordered;
}

/// Where a folded run's tail may start, given it wants to show the last [shown]
/// steps of [ordered] (which must already be [orderedBySubRun]).
///
/// A fold cuts by count, and a count knows nothing about who ran what — so the
/// tail could open on a nested row, which draws stepped in and branching off a
/// trunk with nothing above it. It reads as a step belonging to a row that
/// scrolled away, which is exactly what it is. Pulling the start back to the
/// delegating row costs a couple of rows and makes the group whole.
int runTailStart(List<AgentActivity> ordered, int shown) {
  final start = ordered.length - shown;
  if (start <= 0) return 0;
  final first = ordered[start];
  if (!first.isNested) return start;
  for (var i = start - 1; i >= 0; i--) {
    if (ordered[i].id == first.parent) return i;
  }
  return start;
}

/// How many steps a sub-agent ran, said in words rather than as a bare number.
String _stepCount(int total) => total == 1 ? '1 step' : '$total steps';

/// The live line under a working sub-agent's row: how much it has done, and
/// what it is doing now.
///
/// This is the whole answer to "why has the screen been still for two minutes".
/// A delegating row is the one step in a turn that can hold for that long, and
/// until now it said the same thing at second one and at minute three — the work
/// underneath it was on screen, but nothing tied it to the row that owned it or
/// counted it up.
///
/// Named in the sub-agent's own terms ("Reading conventions.md"), not the
/// parent's, because that is the question being answered: not *what did the
/// agent delegate*, which the row above already says, but *where has that got
/// to*.
String subRunProgress(SubRun run, AgentDetailMode mode) {
  final active = run.active;
  if (active == null) {
    // Between two steps, or not yet at its first. Both are the sub-agent
    // thinking, and neither is worth a different word.
    return run.total == 0 ? 'Starting…' : '${_stepCount(run.total)} · working…';
  }
  final title = agentStepTitle(active);
  final about = agentStepDetail(active, mode);
  final doing = about.isEmpty ? title : '$title $about';
  return '${_stepCount(run.total)} · $doing';
}

/// The line that stands in for a finished sub-agent's folded steps.
///
/// Failures are counted here and nowhere else on the row. A group that hid one
/// behind a fold would be a fold that lied about what happened; painting the
/// delegating row red instead would call an ordinary retry an error (see
/// [SubRun.failed]).
String subRunSummary(SubRun run) {
  final steps = _stepCount(run.total);
  return run.failed == 0 ? steps : '$steps · ${run.failed} failed';
}
