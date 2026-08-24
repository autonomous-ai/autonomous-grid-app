import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/raw_turn_stream.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/presentation/approval_picker.dart';
import 'package:grid_app/features/agents/logic/agent_server_error.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/raw_agent_argv.dart';

/// The value of the `-c` override named [key], or null when the argv carries
/// none — the pair is two separate tokens, so a test that only searched for the
/// value would pass on an override that lost its flag.
String? overrideFor(List<String> args, String key) {
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] != '-c') continue;
    if (args[i + 1].startsWith('$key=')) return args[i + 1];
  }
  return null;
}

void main() {
  group('claudeRawArgs — the turn asks for text, and nothing else', () {
    test('asks for no JSON at all: a single stream-json flag left behind would '
        'put the raw protocol in the bubble instead of the answer', () {
      final args = claudeRawArgs(
        model: 'opus',
        approval: AgentApprovalMode.ask,
      );

      expect(args, contains('-p'));
      expect(args.join(' '), isNot(contains('stream-json')));
      expect(args.join(' '), isNot(contains('--output-format')));
      expect(args.join(' '), isNot(contains('--input-format')));
      // The channel this lane gave up. Passing it without stream-json is worse
      // than not passing it: the CLI takes the flag and never serves it.
      expect(args.join(' '), isNot(contains('--permission-prompt-tool')));
    });

    test('names the model, because the chat picker is the live choice and a '
        'flag beats a file nobody can see', () {
      expect(
        claudeRawArgs(model: 'qwen3-coder', approval: AgentApprovalMode.ask),
        containsAllInOrder(['--model', 'qwen3-coder']),
      );
    });

    test('takes the session schedulers away every turn — they report success '
        'into a process that has already exited', () {
      final args = claudeRawArgs(
        model: 'opus',
        approval: AgentApprovalMode.ask,
      );

      expect(args, contains('--disallowedTools'));
      for (final tool in kClaudeSessionSchedulerTools) {
        expect(args, contains(tool));
      }
    });

    test("the provider's own web tools go only when the endpoint can't serve "
        'them — the relay refuses the whole request, not just the tool', () {
      final withThem = claudeRawArgs(
        model: 'claude:opus',
        approval: AgentApprovalMode.ask,
      );
      final without = claudeRawArgs(
        model: 'qwen3-coder',
        approval: AgentApprovalMode.ask,
        withoutServerWebTools: true,
      );

      expect(withThem, isNot(contains('WebSearch')));
      expect(without, containsAll(kClaudeServerWebTools));
    });

    test('adds --chrome only on the extension lane, since it costs context on '
        'every turn that carries it', () {
      expect(
        claudeRawArgs(
          model: 'opus',
          approval: AgentApprovalMode.ask,
          chrome: true,
        ),
        contains('--chrome'),
      );
      expect(
        claudeRawArgs(model: 'opus', approval: AgentApprovalMode.ask),
        isNot(contains('--chrome')),
      );
    });

    test('a missing MCP config drops both flags: a path that does not exist '
        'aborts the turn outright', () {
      final without = claudeRawArgs(
        model: 'opus',
        approval: AgentApprovalMode.ask,
      );
      final with_ = claudeRawArgs(
        model: 'opus',
        approval: AgentApprovalMode.ask,
        mcpConfigPath: '/tmp/turn.json',
      );

      expect(without, isNot(contains('--mcp-config')));
      expect(without, isNot(contains('--strict-mcp-config')));
      expect(with_, containsAllInOrder(['--mcp-config', '/tmp/turn.json']));
      expect(with_, contains('--strict-mcp-config'));
    });

    test('resumes only when it is handed an id — no chat turn learns one here, '
        'so the flag must never appear by default', () {
      expect(
        claudeRawArgs(model: 'opus', approval: AgentApprovalMode.ask),
        isNot(contains('--resume')),
      );
      expect(
        claudeRawArgs(
          model: 'opus',
          approval: AgentApprovalMode.readOnly,
          resumeSessionId: 'sess-9',
        ),
        containsAllInOrder(['--resume', 'sess-9']),
      );
    });
  });

  group('claudePermissionArgs — what the composer can still promise', () {
    test('full access is the mode the user chose, so it is named outright', () {
      expect(claudePermissionArgs(AgentApprovalMode.full), [
        '--permission-mode',
        'bypassPermissions',
      ]);
    });

    test('plan mode keeps its own flag, which is the one thing it needs', () {
      expect(claudePermissionArgs(AgentApprovalMode.plan), [
        '--permission-mode',
        'plan',
      ]);
    });

    test(
      'look-don\'t-touch and ask-first pass no mode at all: without a prompt '
      'channel there is nothing to ask on, and naming a mode this build may '
      'not accept would fail the whole turn',
      () {
        expect(claudePermissionArgs(AgentApprovalMode.readOnly), isEmpty);
        expect(claudePermissionArgs(AgentApprovalMode.ask), isEmpty);
      },
    );
  });

  group('codexRawArgs — one turn, printed as text', () {
    test('runs `exec` and asks for no JSON: --json here would put the wire '
        'protocol in front of the user', () {
      final args = codexRawArgs(
        model: 'qwen3',
        workdir: '/tmp/project',
        approval: AgentApprovalMode.ask,
      );

      expect(args.first, 'exec');
      expect(args, isNot(contains('--json')));
      expect(args, isNot(contains('app-server')));
    });

    test('opens in the folder the chat belongs to, and starts there even when '
        'it is not a git repo — most chat folders are not', () {
      final args = codexRawArgs(
        model: 'qwen3',
        workdir: '/tmp/project',
        approval: AgentApprovalMode.ask,
      );

      expect(args, containsAllInOrder(['-C', '/tmp/project']));
      expect(args, contains('--skip-git-repo-check'));
    });

    test('turns colour off, so the answer reaches the bubble as words rather '
        'than as terminal escape codes', () {
      expect(
        codexRawArgs(
          model: 'qwen3',
          workdir: '/tmp/p',
          approval: AgentApprovalMode.ask,
        ),
        containsAllInOrder(['--color', 'never']),
      );
    });

    test("the chat's mode still reaches the sandbox, which is the only gate "
        'left once nobody can be asked', () {
      List<String> argsFor(AgentApprovalMode mode) =>
          codexRawArgs(model: 'qwen3', workdir: '/tmp/p', approval: mode);

      expect(
        argsFor(AgentApprovalMode.readOnly),
        containsAllInOrder(['-s', 'read-only']),
      );
      expect(
        argsFor(AgentApprovalMode.ask),
        containsAllInOrder(['-s', 'workspace-write']),
      );
      expect(
        argsFor(AgentApprovalMode.full),
        containsAllInOrder(['-s', 'danger-full-access']),
      );
    });

    test('every config override rides as its own `-c` pair, the grid included, '
        'so nothing of the user\'s config.toml is rewritten', () {
      final args = codexRawArgs(
        model: 'qwen3',
        workdir: '/tmp/p',
        approval: AgentApprovalMode.full,
        config: const ['model_provider="grid-app"', 'model="qwen3"'],
      );

      expect(overrideFor(args, 'model_provider'), 'model_provider="grid-app"');
      expect(overrideFor(args, 'model'), 'model="qwen3"');
      expect(overrideFor(args, 'approval_policy'), 'approval_policy="never"');
    });
  });

  group(
    'codexApprovalPolicy — the composer, as far as `exec` can carry it',
    () {
      test(
        'look-don\'t-touch cannot write, which is the promise the label makes',
        () {
          expect(
            codexApprovalPolicy(AgentApprovalMode.readOnly).sandbox,
            'read-only',
          );
          expect(
            codexApprovalPolicy(AgentApprovalMode.readOnly).policy,
            'never',
          );
        },
      );

      test(
        'ask-first keeps Codex\'s own "untrusted" judgement: nobody can answer '
        'a card here, so what it will not run unattended it refuses and says '
        'why — and that refusal is what the user reads',
        () {
          expect(
            codexApprovalPolicy(AgentApprovalMode.ask).policy,
            'untrusted',
          );
          expect(
            codexApprovalPolicy(AgentApprovalMode.ask).sandbox,
            'workspace-write',
          );
        },
      );

      test(
        'full access is the widest, and only because the user picked it',
        () {
          expect(
            codexApprovalPolicy(AgentApprovalMode.full).sandbox,
            'danger-full-access',
          );
        },
      );
    },
  );

  group('rawTurnFailure — the agent reports itself wherever it can', () {
    test('a turn that answered is not a failure', () {
      expect(
        rawTurnFailure(output: 'Here you go.', exitCode: 0, agentName: 'Codex'),
        isNull,
      );
    });

    test("a turn that failed after starting reports in its own words — the app "
        'must not replace what the agent already said with a guess', () {
      expect(
        rawTurnFailure(
          output: 'error: no providers available for this model',
          exitCode: 1,
          agentName: 'Codex',
        ),
        'error: no providers available for this model',
      );
    });

    test('a CLI that never started is the app\'s own line, because there is no '
        'agent output to show instead', () {
      final line = rawTurnFailure(
        output: '',
        exitCode: 127,
        agentName: 'Claude Code',
        startFailure: 'No such file or directory',
      );

      expect(line, contains('Claude Code'));
      expect(line, contains('No such file or directory'));
    });

    test('a turn that died silently says so with its exit code, rather than '
        'leaving the chat with an empty bubble', () {
      expect(
        rawTurnFailure(output: '', exitCode: 137, agentName: 'Codex'),
        contains('137'),
      );
    });

    test(
      'a clean exit with nothing to show reads the same for every agent',
      () {
        expect(
          rawTurnFailure(output: '', exitCode: 0, agentName: 'Codex'),
          kAgentNoAnswer,
        );
      },
    );
  });

  group('the composer says what the agent can actually do', () {
    test('an agent with no channel to ask never offers to — the label used to '
        'promise a card that cannot appear', () {
      expect(AgentTool.hermes.asksPermission, isTrue);
      expect(AgentTool.claude.asksPermission, isFalse);
      expect(AgentTool.codex.asksPermission, isFalse);
    });

    test('"ask before acting" keeps its words only where something asks', () {
      expect(approvalLabel(AgentApprovalMode.ask), 'Ask before acting');
      expect(
        approvalLabel(AgentApprovalMode.ask, canAsk: false),
        isNot('Ask before acting'),
      );
    });

    test('the detail says what happens instead: it refuses, rather than '
        'waiting for a yes nobody will be shown', () {
      final line = approvalDetail(AgentApprovalMode.ask, canAsk: false);

      expect(line, contains('refuses'));
      expect(line.toLowerCase(), isNot(contains('waits for a yes')));
    });

    test(
      'the two modes that never promised a card read the same either way — '
      'read-only cannot write and full access does not ask, whoever runs it',
      () {
        for (final mode in [
          AgentApprovalMode.readOnly,
          AgentApprovalMode.full,
        ]) {
          expect(
            approvalDetail(mode, canAsk: false),
            approvalDetail(mode),
            reason: '${mode.name} should not change with the channel',
          );
        }
      },
    );
  });
}
