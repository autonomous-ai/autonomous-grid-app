import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

void main() {
  group('parseAgentPlan — the agent’s to-do list off an ACP plan update', () {
    test(
      'reads each entry and maps ACP statuses to the app’s three states',
      () {
        final plan = parseAgentPlan([
          {'content': 'Read the files', 'status': 'completed'},
          {'content': 'Make the change', 'status': 'in_progress'},
          {'content': 'Run the tests', 'status': 'pending'},
        ]);

        expect(plan.map((e) => e.content), [
          'Read the files',
          'Make the change',
          'Run the tests',
        ]);
        expect(plan.map((e) => e.status), [
          AgentPlanStatus.done,
          AgentPlanStatus.active,
          AgentPlanStatus.pending,
        ]);
      },
    );

    test('an unknown or missing status reads as pending — never as done', () {
      final plan = parseAgentPlan([
        {'content': 'a', 'status': 'cancelled'},
        {'content': 'b'},
      ]);
      expect(plan.map((e) => e.status), [
        AgentPlanStatus.pending,
        AgentPlanStatus.pending,
      ]);
    });

    test('a blank step is dropped rather than shown as an empty row', () {
      final plan = parseAgentPlan([
        {'content': '   ', 'status': 'pending'},
        {'content': 'real step', 'status': 'pending'},
      ]);
      expect(plan.map((e) => e.content), ['real step']);
    });

    test('a non-list (or empty) payload is an empty plan, never a throw', () {
      expect(parseAgentPlan(null), isEmpty);
      expect(parseAgentPlan('nope'), isEmpty);
      expect(parseAgentPlan(const []), isEmpty);
    });

    test(
      "Hermes's own placeholders are dropped, not shown as a wall of "
      '"(no description)" when a weak model fills the plan with no text',
      () {
        final plan = parseAgentPlan([
          {'content': '(no description)', 'status': 'in_progress'},
          {'content': 'Add helmet', 'status': 'pending'},
          {'content': '(invalid item)', 'status': 'pending'},
          // Case-folded so the same placeholder in any casing is caught.
          {'content': '(No Description)', 'status': 'pending'},
        ]);
        expect(plan.map((e) => e.content), ['Add helmet']);
      },
    );

    test('a persisted placeholder is dropped on reload too', () {
      expect(
        AgentPlanEntry.fromJson(const {
          'content': '(no description)',
          'status': 'pending',
        }),
        isNull,
      );
    });

    test(
      'an entry round-trips through JSON so a saved plan restores its status',
      () {
        const entry = AgentPlanEntry(
          content: 'Ship it',
          status: AgentPlanStatus.active,
        );
        final restored = AgentPlanEntry.fromJson(entry.toJson());
        expect(restored?.content, 'Ship it');
        expect(restored?.status, AgentPlanStatus.active);
      },
    );
  });
}
