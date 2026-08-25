import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:grid_app/features/agents/logic/adapters/agent_terminal_command.dart';
import 'package:grid_app/features/agents/logic/adapters/raw_turn_stream.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/infrastructure/cli/host_environment.dart';
import 'package:grid_app/shared/terminal/terminal_shell.dart';
import 'package:grid_app/shared/terminal/terminal_text.dart';
import 'package:grid_app/features/agents/logic/agent_server_error.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_session_id.dart';
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

  group('agentTerminalCommand — the agent CLI, as the user would run it', () {
    ShellCommand claude({
      AgentApprovalMode approval = AgentApprovalMode.ask,
      String? mcpConfigPath,
      AgentSession? session,
      String? prompt,
    }) => agentTerminalCommand(
      tool: AgentTool.claude,
      executable: '/bin/claude',
      model: 'opus',
      workdir: '/tmp/project',
      approval: approval,
      mcpConfigPath: mcpConfigPath,
      session: session,
      prompt: prompt,
    );

    ShellCommand codex({
      AgentApprovalMode approval = AgentApprovalMode.ask,
      List<String> config = const [],
      AgentSession? session,
      String? prompt,
    }) => agentTerminalCommand(
      tool: AgentTool.codex,
      executable: '/bin/codex',
      model: 'qwen3',
      workdir: '/tmp/project',
      approval: approval,
      config: config,
      session: session,
      prompt: prompt,
    );

    test(
      'the message that started the chat is the CLI\'s own last argument, so '
      'the session opens with it already asked rather than the app guessing '
      'when the TUI is ready to be typed at',
      () {
        expect(
          claude(prompt: 'Bạn tên Peter?').arguments.last,
          'Bạn tên Peter?',
        );
        expect(
          codex(prompt: 'Bạn tên Peter?').arguments.last,
          'Bạn tên Peter?',
        );
        expect(claude().arguments.last, isNot('Bạn tên Peter?'));
      },
    );

    test(
      'a resumed Codex session takes no prompt: `resume` reads the positional '
      'as the session id, so a message there would name a session that does '
      'not exist',
      () {
        final args = codex(
          session: (id: 'sess-1', resume: true),
          prompt: 'carry on',
        ).arguments;
        expect(args, isNot(contains('carry on')));
        expect(args.take(2), ['resume', 'sess-1']);
      },
    );

    test(
      'runs the REPL, not the one-shot mode: `-p` here would print an answer '
      'and exit, and there would be nothing to type into',
      () {
        expect(claude().arguments, isNot(contains('-p')));
        expect(codex().arguments, isNot(contains('exec')));
      },
    );

    test('starts the binary the app resolved, so a machine with two installs '
        'runs the one the rest of the app talks about', () {
      expect(claude().executable, '/bin/claude');
      expect(codex().executable, '/bin/codex');
    });

    test(
      'never passes `--skip-git-repo-check` to the interactive Codex — '
      '`codex --help` does not list it, and an unknown flag kills the session '
      'before the TUI draws, which reads as a terminal that flashed and died',
      () {
        expect(codex().arguments, isNot(contains('--skip-git-repo-check')));
      },
    );

    test('tells Codex which folder is its working root, and hands it the grid '
        'as `-c` overrides', () {
      final args = codex(config: const ['model_provider="grid-app"']).arguments;

      expect(args, containsAllInOrder(['-C', '/tmp/project']));
      expect(args, containsAllInOrder(['-m', 'qwen3']));
      expect(overrideFor(args, 'model_provider'), 'model_provider="grid-app"');
    });

    test("the chat's mode reaches both CLIs, so the picker means the same thing "
        'here as it does in a terminal', () {
      expect(
        codex(approval: AgentApprovalMode.readOnly).arguments,
        containsAllInOrder(['-s', 'read-only']),
      );
      expect(
        claude(approval: AgentApprovalMode.full).arguments,
        containsAllInOrder(['--permission-mode', 'bypassPermissions']),
      );
      // Ask-first passes no mode: interactive Claude Code's own default gate is
      // the one that stops and asks, which is the whole point of this lane.
      expect(claude().arguments, isNot(contains('--permission-mode')));
    });

    test('takes the session schedulers away here too — they die with the '
        'process whichever way it was started', () {
      expect(claude().arguments, contains('--disallowedTools'));
      for (final tool in kClaudeSessionSchedulerTools) {
        expect(claude().arguments, contains(tool));
      }
    });

    test('a missing MCP config drops both flags, as it does for a one-shot '
        'turn: a path that is not there aborts the session outright', () {
      expect(claude().arguments, isNot(contains('--mcp-config')));
      expect(claude().arguments, isNot(contains('--strict-mcp-config')));
      expect(
        claude(mcpConfigPath: '/tmp/turn.json').arguments,
        containsAllInOrder(['--mcp-config', '/tmp/turn.json']),
      );
    });

    test('Hermes has no interactive CLI to run, and the capability says so — a '
        'chat with it must never reach this lane', () {
      expect(AgentTool.claude.runsInTerminal, isTrue);
      expect(AgentTool.codex.runsInTerminal, isTrue);
      expect(AgentTool.hermes.runsInTerminal, isFalse);
    });
  });

  group('a chat keeps the conversation its CLI is holding', () {
    ShellCommand claude({AgentSession? session}) => agentTerminalCommand(
      tool: AgentTool.claude,
      executable: '/bin/claude',
      model: 'opus',
      workdir: '/tmp/project',
      approval: AgentApprovalMode.ask,
      session: session,
    );
    ShellCommand codex({AgentSession? session}) => agentTerminalCommand(
      tool: AgentTool.codex,
      executable: '/bin/codex',
      model: 'qwen3',
      workdir: '/tmp/project',
      approval: AgentApprovalMode.ask,
      session: session,
    );

    test('Claude Code is told the id on the launch that creates the session, '
        'and asked for it back on every one after — measured on 2.1.243, '
        'passing --session-id twice is refused outright', () {
      expect(
        claude(session: (id: 'abc', resume: false)).arguments,
        containsAllInOrder(['--session-id', 'abc']),
      );
      expect(
        claude(session: (id: 'abc', resume: true)).arguments,
        containsAllInOrder(['--resume', 'abc']),
      );
      expect(claude().arguments, isNot(contains('--session-id')));
      expect(claude().arguments, isNot(contains('--resume')));
    });

    test(
      "Codex's resume is a subcommand, so it leads the argv and keeps its id "
      'beside it — an option in between is how a variadic flag swallows the '
      'thing it was meant to resume',
      () {
        final args = codex(session: (id: 'uuid-1', resume: true)).arguments;
        expect(args.take(2), ['resume', 'uuid-1']);
        // The rest of the session still reaches it: `codex resume` takes these,
        // and only `--skip-git-repo-check` is missing from its list.
        expect(args, containsAllInOrder(['-C', '/tmp/project']));
        expect(args, containsAllInOrder(['-m', 'qwen3']));
      },
    );

    test('a Codex chat with nothing to resume starts the plain TUI, because '
        'there is no flag that can hand it an id up front', () {
      expect(codex().arguments, isNot(contains('resume')));
      expect(
        codex(session: (id: 'x', resume: false)).arguments,
        isNot(contains('resume')),
      );
    });
  });

  group('newAgentSessionId — the CLI parses it and names a file after it', () {
    test('it is a v4 UUID, not merely something unique', () {
      final id = newAgentSessionId(Random(7));
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}'
            r'-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('two chats opened in the same breath never share one, or the second '
        'is refused and answers out of the first chat', () {
      final ids = {for (var i = 0; i < 200; i++) newAgentSessionId()};
      expect(ids, hasLength(200));
    });
  });

  group('pickCodexSession — read back, because Codex cannot be told one', () {
    const dir = '/home/u/.codex/sessions/2026/08/25';
    const mine =
        '$dir/rollout-2026-08-25T10-24-50-'
        '01a036f3-005e-7dc0-95af-62aa6efd3385.jsonl';
    const other =
        '$dir/rollout-2026-08-25T10-31-02-'
        '01a036d4-4c50-78f1-9411-2ad5f47fb911.jsonl';
    const workdir = '/Users/u/.grid/app/agent-workspace';

    CodexRolloutMeta meta({
      String originator = kCodexTuiOriginator,
      String cwd = workdir,
      String id = '01a036f3-005e-7dc0-95af-62aa6efd3385',
    }) => (originator: originator, cwd: cwd, sessionId: id);

    test('the rollout this app\'s terminal wrote in this folder is the session '
        'it started', () {
      expect(
        pickCodexSession(fresh: {mine: meta()}, workdir: workdir),
        '01a036f3-005e-7dc0-95af-62aa6efd3385',
      );
    });

    test('Codex Desktop writing into the same folder is not this chat — it was '
        'there on the machine this was written for, working in another project '
        'entirely, and counting it refused the real one', () {
      expect(
        pickCodexSession(
          fresh: {
            mine: meta(),
            other: meta(
              originator: 'Codex Desktop',
              cwd: '/Users/u/WorkPlace/something-else',
            ),
          },
          workdir: workdir,
        ),
        '01a036f3-005e-7dc0-95af-62aa6efd3385',
      );
    });

    test('a `codex exec` turn is not this chat either, even in the same '
        'folder — the one-shot lane writes here too', () {
      expect(
        pickCodexSession(
          fresh: {other: meta(originator: 'codex_exec')},
          workdir: workdir,
        ),
        isNull,
      );
    });

    test('a terminal opened on another folder is another chat', () {
      expect(
        pickCodexSession(
          fresh: {other: meta(cwd: '/Users/u/projects/api')},
          workdir: workdir,
        ),
        isNull,
      );
    });

    test('two of this app\'s own terminals in one folder answer nothing rather '
        "than guess — a wrong id resumes a stranger's conversation, which does "
        'not look like a bug', () {
      expect(
        pickCodexSession(
          fresh: {
            mine: meta(),
            other: meta(id: 'other-id'),
          },
          workdir: workdir,
        ),
        isNull,
      );
    });

    test('a rollout caught before its first line landed is "not yet", not a '
        'wrong answer', () {
      expect(pickCodexSession(fresh: {mine: null}, workdir: workdir), isNull);
    });

    test('the uuid is read off the end of the name, since the timestamp in the '
        'middle carries dashes of its own', () {
      expect(
        codexSessionIdFromPath(mine),
        '01a036f3-005e-7dc0-95af-62aa6efd3385',
      );
      expect(codexSessionIdFromPath('$dir/notes.jsonl'), isNull);
    });
  });

  group('parseCodexRolloutMeta — whose session is this', () {
    test(
      "the fields that say who wrote it are read off the session_meta line",
      () {
        const line =
            '{"timestamp":"2026-08-25T03:39:07.142Z","type":"session_meta",'
            '"payload":{"session_id":"01a03700-11eb-7c53-a11b-bd0a6a775a09",'
            '"cwd":"/Users/u/.grid/app/agent-workspace","originator":"codex-tui",'
            '"cli_version":"0.144.6"}}';
        final meta = parseCodexRolloutMeta(line);
        expect(meta?.originator, kCodexTuiOriginator);
        expect(meta?.cwd, '/Users/u/.grid/app/agent-workspace');
        expect(meta?.sessionId, '01a03700-11eb-7c53-a11b-bd0a6a775a09');
      },
    );

    test('a half-written line reads as "cannot tell" rather than throwing on a '
        'background poll', () {
      expect(parseCodexRolloutMeta('{"type":"session_m'), isNull);
      expect(parseCodexRolloutMeta(''), isNull);
      expect(parseCodexRolloutMeta('{"type":"turn","payload":{}}'), isNull);
    });
  });

  group('quoteForWindowsPty — the argv has to survive being a command line', () {
    test('a program whose path has a space in it stays one token, or Windows '
        'starts the wrong program and dies before the TUI draws', () {
      final quoted = quoteForWindowsPty((
        executable: r'C:\Program Files\Claude\claude.exe',
        arguments: const [],
      ));
      expect(quoted.executable, r'"C:\Program Files\Claude\claude.exe"');
    });

    test('a path with nothing to quote is left exactly as it was', () {
      final quoted = quoteForWindowsPty((
        executable: 'claude',
        arguments: const ['--model', 'sonnet'],
      ));
      expect(quoted.executable, 'claude');
      expect(quoted.arguments, ['--model', 'sonnet']);
    });

    test(
      "Codex's -c override keeps its quotes, or the value it sets stops being "
      'a TOML string',
      () {
        final quoted = quoteForWindowsPty((
          executable: 'codex',
          arguments: const ['-c', 'approval_policy="on-request"'],
        ));
        expect(quoted.arguments.last, r'"approval_policy=\"on-request\""');
      },
    );

    test('a directory argument ending in a separator doubles it, or the '
        'separator escapes the quote that closes the argument', () {
      expect(windowsArgument('C:\\a folder\\'), r'"C:\a folder\\"');
    });
  });

  group('withoutInheritedAgentSession — a chat opens a session of its own', () {
    test("another Claude Code session's name and message pipe do not travel "
        'into the CLI this app starts', () {
      final scrubbed = withoutInheritedAgentSession(const {
        'CLAUDE_CODE_CHILD_SESSION': '1',
        'CLAUDE_CODE_SESSION_ID': '999f9db5-06ca-4b92-a0f0-2207cb5bae26',
        'CLAUDE_CODE_MESSAGING_SOCKET': r'\\.\pipe\LOCAL\cc-msg-baadf3',
        'CLAUDE_CODE_MESSAGING_TOKEN': '2e91a4256e5094954a6215101b49de9c',
        'CLAUDECODE': '1',
      });
      expect(scrubbed, isEmpty);
    });

    test('everything else is left exactly where it was, the grid settings the '
        'CLI actually answers from included', () {
      final scrubbed = withoutInheritedAgentSession(const {
        'PATH': '/usr/bin',
        'ANTHROPIC_BASE_URL': 'http://127.0.0.1:8787',
        'ANTHROPIC_MODEL': 'DeepSeek-V4-Flash-0731',
        'CLAUDE_CODE_ENTRYPOINT': 'claude-vscode',
      });
      expect(scrubbed, {
        'PATH': '/usr/bin',
        'ANTHROPIC_BASE_URL': 'http://127.0.0.1:8787',
        'ANTHROPIC_MODEL': 'DeepSeek-V4-Flash-0731',
      });
    });

    test('a variable that only configures the CLI stays, because a user is as '
        'likely to have exported it on purpose', () {
      expect(
        withoutInheritedAgentSession(const {
          'CLAUDE_CODE_AUTO_COMPACT_WINDOW': '200000',
        }),
        {'CLAUDE_CODE_AUTO_COMPACT_WINDOW': '200000'},
      );
    });
  });

  group('windowsPtyCommand — the CLI must not be handed its own name', () {
    test('the program is run through cmd, which is what swallows the copy of '
        'itself that flutter_pty puts at argv[0]', () {
      final spawn = windowsPtyCommand((
        executable: r'C:\claude\claude.exe',
        arguments: const ['--model', 'glm-4.7-flash'],
      ));
      expect(spawn.executable, 'cmd.exe');
      expect(spawn.arguments.first, '/c');
      expect(spawn.arguments, hasLength(2));
    });

    test('the whole command travels as one quoted argument, because cmd drops '
        'the outer pair and runs precisely what was inside it', () {
      final spawn = windowsPtyCommand((
        executable: r'C:\Program Files\Claude\claude.exe',
        arguments: const ['--model', 'glm-4.7-flash'],
      ));
      expect(
        spawn.arguments.last,
        r'""C:\Program Files\Claude\claude.exe" --model glm-4.7-flash"',
      );
    });

    test('a Codex override survives being read twice — once by cmd and once by '
        'Codex', () {
      final spawn = windowsPtyCommand((
        executable: 'codex',
        arguments: const ['-c', 'approval_policy="on-request"'],
      ));
      expect(
        spawn.arguments.last,
        r'"codex -c "approval_policy=\"on-request\"""',
      );
    });

    test('an argument holding a character cmd reads as punctuation is quoted, '
        'or cmd acts on it instead of passing it on', () {
      expect(cmdSafeArgument(r'C:\Work & Play\bin'), r'"C:\Work & Play\bin"');
      expect(cmdSafeArgument('--model'), '--model');
      expect(
        cmdSafeArgument(r'"already quoted & fine"'),
        r'"already quoted & fine"',
      );
    });
  });

  group('selectionText — what leaves the terminal has to be what it says', () {
    /// A terminal with [lines] already drawn on it, 40 columns wide.
    Terminal painted(List<String> writes) {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(40, 8);
      for (final write in writes) {
        terminal.write(write);
      }
      return terminal;
    }

    BufferRange row(int line) =>
        BufferRangeLine(CellOffset(0, line), CellOffset(39, line));

    test(
      'the gaps a TUI jumps over are spaces, not nothing — the CLI permission '
      'warning copied as "runningin Bypass Permissionsmode" without this',
      () {
        // Ink draws a run, moves the cursor, draws the next: the cells in
        // between are never written to at all.
        final terminal = painted(['WARNING:', '[15GBypass']);
        expect(selectionText(terminal.buffer, row(0)), 'WARNING:      Bypass');
      },
    );

    test(
      'a line padded out to the window is trimmed, not pasted as padding',
      () {
        final terminal = painted(['done']);
        expect(selectionText(terminal.buffer, row(0)), 'done');
      },
    );

    test('a double-width character keeps its own width and gains no space', () {
      final terminal = painted(['a漢b']);
      expect(selectionText(terminal.buffer, row(0)), 'a漢b');
    });

    test('two rows come back as two lines, since that is what was read', () {
      final terminal = painted(['first[2;1Hsecond']);
      expect(
        selectionText(
          terminal.buffer,
          BufferRangeLine(CellOffset(0, 0), CellOffset(39, 1)),
        ),
        'first\nsecond',
      );
    });
  });

  group(
    'droppedPathsLine — a file dropped on a terminal is typed, not sent',
    () {
      test('a plain path is typed as it is, so the user can read it back', () {
        expect(droppedPathsLine([r'C:\src\main.dart']), r'C:\src\main.dart');
      });

      test(
        'a path with a space is quoted, or the CLI reads two half-paths',
        () {
          expect(
            droppedPathsLine([r'C:\My Files\notes.md']),
            r'"C:\My Files\notes.md"',
          );
        },
      );

      test('several files land as several arguments on one line', () {
        expect(
          droppedPathsLine(['/a/one.md', '/b/two.md']),
          '/a/one.md /b/two.md',
        );
      });

      test('a quote in a name is escaped rather than ending the argument', () {
        expect(droppedPath('/tmp/say "hi".txt'), r'"/tmp/say \"hi\".txt"');
      });
    },
  );
}
