import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_step_label.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

AgentActivity _step(
  String label, {
  AgentActivityKind kind = AgentActivityKind.command,
}) => AgentActivity(
  id: 'x',
  kind: kind,
  label: label,
  status: AgentActivityStatus.done,
);

void main() {
  group('commandProgram', () {
    test('names the program without its path or arguments', () {
      expect(commandProgram('rg -n "foo" lib | head -20'), 'rg');
      expect(commandProgram('/usr/bin/env python script.py'), 'env');
      expect(commandProgram('  git   status  '), 'git');
    });

    test('skips the environment a command is given before it runs', () {
      expect(commandProgram('FOO=1 BAR=2 pytest -q'), 'pytest');
    });

    test('steps over punctuation and names what it feeds', () {
      expect(commandProgram('| grep foo'), 'grep');
      expect(commandProgram('&& make build'), 'make');
    });

    test('gives up rather than printing a fragment as a program name', () {
      expect(commandProgram(''), isEmpty);
      expect(commandProgram('   '), isEmpty);
      expect(commandProgram('"quoted thing"'), isEmpty);
    });
  });

  group('agentStepLabel', () {
    test('the fullest level shows what actually ran, unchanged', () {
      expect(
        agentStepLabel(_step('rg -n "foo" lib'), AgentDetailMode.stepsCommands),
        'rg -n "foo" lib',
      );
    });

    test('the middle level names the program instead of the command line — a '
        'user who does not read shell can still follow along', () {
      expect(
        agentStepLabel(_step('rg -n "foo" lib | head'), AgentDetailMode.steps),
        'Ran rg',
      );
    });

    test('a command with no nameable program still says something true', () {
      expect(
        agentStepLabel(_step('"a quoted thing"'), AgentDetailMode.steps),
        'Ran a command',
      );
    });

    test('a web step reads as what it was, not as a URL', () {
      expect(
        agentStepLabel(
          _step('https://example.com/search?q=x', kind: AgentActivityKind.web),
          AgentDetailMode.steps,
        ),
        'Searched the web',
      );
    });

    test('a tool keeps its name — it is a name, not a command line', () {
      expect(
        agentStepLabel(
          _step('read_file', kind: AgentActivityKind.tool),
          AgentDetailMode.steps,
        ),
        'read_file',
      );
    });
  });
}
