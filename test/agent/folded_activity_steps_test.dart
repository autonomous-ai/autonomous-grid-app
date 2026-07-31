import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_providers.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

/// What a long run shows while it is folded — the summary has to stay a summary,
/// or the answer and the "Thinking…" line disappear under the agent's file
/// reads.
void main() {
  AgentActivity step(
    String id, {
    AgentActivityStatus status = AgentActivityStatus.done,
  }) => AgentActivity(
    id: id,
    kind: AgentActivityKind.tool,
    label: 'read: $id',
    status: status,
  );

  List<String> idsOf(List<AgentActivity> steps) => [
    for (final s in steps) s.id,
  ];

  test('a short run is shown whole — there is nothing worth hiding', () {
    final steps = [step('a'), step('b'), step('c')];
    expect(idsOf(foldedActivitySteps(steps)), ['a', 'b', 'c']);
  });

  test('an agent that reads three dozen files at once still shows five rows, so '
      'the reply it is working towards stays on screen', () {
    final steps = [
      for (var i = 0; i < 36; i++)
        step('f$i', status: AgentActivityStatus.running),
    ];

    final folded = foldedActivitySteps(steps);

    expect(folded, hasLength(kFoldedStepLimit));
    // The latest work, in the order it ran — not the first five it started with.
    expect(idsOf(folded), ['f31', 'f32', 'f33', 'f34', 'f35']);
  });

  test('a slow command still running is kept even when newer steps finished '
      'first, so the one thing actually holding the turn up stays visible', () {
    final steps = [
      step('slow-build', status: AgentActivityStatus.running),
      for (var i = 0; i < 8; i++) step('quick-read-$i'),
    ];

    final folded = foldedActivitySteps(steps);

    expect(idsOf(folded).first, 'slow-build');
    expect(folded, hasLength(kFoldedStepLimit));
    // Room left over goes to the most recent settled steps, still in run order.
    expect(idsOf(folded).skip(1), [
      'quick-read-4',
      'quick-read-5',
      'quick-read-6',
      'quick-read-7',
    ]);
  });

  test('a folded run between tool calls shows its last steps rather than going '
      'blank, which used to read as an agent doing nothing', () {
    final steps = [for (var i = 0; i < 10; i++) step('done-$i')];

    expect(foldedActivitySteps(steps), hasLength(kFoldedStepLimit));
  });
}
