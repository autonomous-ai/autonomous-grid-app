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

  group('agentToolFamily', () {
    test('a tool search is a search, not the wrench kept for tools nobody '
        'has claimed', () {
      expect(
        agentToolFamily(
          _step('ToolSearch · Monitor', kind: AgentActivityKind.tool),
        ),
        AgentToolFamily.search,
      );
    });

    test('a sub-agent row is a sub-agent under the name Claude Code 2.x uses '
        '— it drew the unclaimed wrench while only `Task` was listed', () {
      final agent = _step(
        'Agent · Review the diff',
        kind: AgentActivityKind.tool,
      );
      expect(agentToolFamily(agent), AgentToolFamily.subAgent);
      expect(
        agentStepTitle(
          AgentActivity(
            id: 'a',
            kind: AgentActivityKind.tool,
            label: 'Agent · Review the diff',
            status: AgentActivityStatus.running,
            tool: 'Agent',
          ),
        ),
        'Working',
      );
    });
  });

  group('stepRequestLanguage', () {
    AgentActivity call(
      String tool,
      String label,
      String request, {
      AgentActivityKind kind = AgentActivityKind.tool,
    }) => AgentActivity(
      id: 'x',
      kind: kind,
      label: label,
      status: AgentActivityStatus.done,
      tool: tool,
      request: request,
    );

    test('a command line is coloured as shell', () {
      expect(
        stepRequestLanguage(
          call('Bash', 'Bash · ls', 'ls -la', kind: AgentActivityKind.command),
        ),
        'bash',
      );
    });

    test('a file change is coloured as the diff it is', () {
      expect(
        stepRequestLanguage(
          call('Edit', 'Edit · a.dart', '--- /r/a.dart\n+++ /r/a.dart\n-a\n+b'),
        ),
        'diff',
      );
    });

    test('a written file is coloured as its own language', () {
      expect(
        stepRequestLanguage(
          call('Write', 'Write · main.dart', 'void main() {}'),
        ),
        'dart',
      );
    });

    test('a written file with no grammar to colour it falls back to the rules '
        'for any request', () {
      expect(
        stepRequestLanguage(call('Write', 'Write · notes.zzz', 'hello')),
        '',
      );
    });

    test('arguments are coloured as JSON', () {
      expect(
        stepRequestLanguage(
          call('Grep', 'Grep · foo', '{\n  "pattern": "foo"\n}'),
        ),
        'json',
      );
    });

    test('anything else stays plain rather than coloured by a guess', () {
      expect(stepRequestLanguage(call('Other', 'Other', 'some output')), '');
    });
  });

  group('a connector row, in either lane', () {
    AgentActivity call(String label, String tool) => AgentActivity(
      id: 'm',
      kind: AgentActivityKind.tool,
      label: label,
      status: AgentActivityStatus.done,
      tool: tool,
    );

    test('is titled by its server, not its wire identifier, with the rest '
        'beside it', () {
      final step = call(
        'gitnexus · impact · ChatStore',
        'mcp__gitnexus__impact',
      );
      expect(agentStepTitle(step), 'gitnexus');
      expect(
        agentStepDetail(step, AgentDetailMode.stepsCommands),
        'impact · ChatStore',
      );
    });

    test('a browser row keeps the word its label opens with', () {
      final step = call(
        'Browser · navigate page · example.com',
        'mcp__claude-in-chrome__navigate_page',
      );
      expect(agentStepTitle(step), 'Browser');
      expect(
        agentStepDetail(step, AgentDetailMode.stepsCommands),
        'navigate page · example.com',
      );
    });
  });

  group('the rows Codex commands and patches become', () {
    test('take the glyph of what they did', () {
      expect(
        agentToolFamily(_step('List · lib', kind: AgentActivityKind.tool)),
        AgentToolFamily.list,
      );
      expect(
        agentToolFamily(_step('Delete · a.dart', kind: AgentActivityKind.tool)),
        AgentToolFamily.edit,
      );
    });

    test('a diff sent with git headers is still coloured as a diff', () {
      expect(
        stepRequestLanguage(
          AgentActivity(
            id: 'x',
            kind: AgentActivityKind.tool,
            label: 'Edit · a.dart',
            status: AgentActivityStatus.done,
            tool: 'Edit',
            request: 'diff --git a/a.dart b/a.dart\n--- a/a.dart\n+++ b/a.dart',
          ),
        ),
        'diff',
      );
    });
  });
}
