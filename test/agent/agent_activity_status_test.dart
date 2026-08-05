import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

/// The status a folded run shows in one line, so the summary spins while work is
/// live and only turns red once a settled run actually has a failure to surface.
void main() {
  AgentActivity step(AgentActivityStatus status) => AgentActivity(
    id: 'id-${status.name}',
    kind: AgentActivityKind.command,
    label: 'terminal: ls',
    status: status,
  );

  test('a run with anything still running reads as running — even past a '
      'failure — so the summary stays live, not prematurely red', () {
    final steps = [
      step(AgentActivityStatus.done),
      step(AgentActivityStatus.failed),
      step(AgentActivityStatus.running),
    ];
    expect(aggregateActivityStatus(steps), AgentActivityStatus.running);
  });

  test('a settled run with a failure reads as failed, so the fold surfaces the '
      'problem instead of a calm check', () {
    final steps = [
      step(AgentActivityStatus.done),
      step(AgentActivityStatus.failed),
      step(AgentActivityStatus.done),
    ];
    expect(aggregateActivityStatus(steps), AgentActivityStatus.failed);
  });

  test('a run where every step finished cleanly reads as done', () {
    final steps = [
      step(AgentActivityStatus.done),
      step(AgentActivityStatus.done),
    ];
    expect(aggregateActivityStatus(steps), AgentActivityStatus.done);
  });

  test('an empty run reads as done rather than throwing', () {
    expect(aggregateActivityStatus(const []), AgentActivityStatus.done);
  });
}
