import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_browser.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';
import 'package:grid_app/infrastructure/cli/claude_stream_parser.dart';

ClaudeBrowserPlan planWith({
  String model = 'claude:opus',
  ChromeExtensionState extensionState = ChromeExtensionState.ready,
  bool cliSupportsChrome = true,
  bool cdpReady = true,
}) => planClaudeBrowser(
  model: model,
  extensionState: extensionState,
  cliSupportsChrome: cliSupportsChrome,
  cdpReady: cdpReady,
);

void main() {
  group('picking a browser lane', () {
    test('a Claude seat with the extension connected drives the real browser, '
        'because that is the browser holding the user\'s logins', () {
      expect(planWith().lane, ClaudeBrowserLane.extension);
    });

    test('a grid model never takes the extension lane: the turn carries relay '
        'credentials, which the extension refuses', () {
      final plan = planWith(model: 'qwen3-coder-30b');
      expect(plan.lane, ClaudeBrowserLane.cdp);
      expect(plan.reason, contains('grid model'));
    });

    test('a Claude seat falls back while Chrome has not been restarted, and '
        'the reason names the restart', () {
      final plan = planWith(extensionState: ChromeExtensionState.hostPending);
      expect(plan.lane, ClaudeBrowserLane.cdp);
      expect(plan.reason, contains('restarted'));
    });

    test('a build without --chrome falls back rather than passing a flag it '
        'would reject', () {
      final plan = planWith(cliSupportsChrome: false);
      expect(plan.lane, ClaudeBrowserLane.cdp);
      expect(plan.reason, contains('--chrome'));
    });

    test('no extension and no fallback browser leaves the turn without one, '
        'and says which piece is missing', () {
      final plan = planWith(
        extensionState: ChromeExtensionState.missing,
        cdpReady: false,
      );
      expect(plan.lane, ClaudeBrowserLane.none);
      expect(plan.reason, contains('extension'));
    });

    test('a multi-model selection with one foreign model stays off the '
        'extension lane', () {
      expect(
        planWith(model: 'claude:opus, qwen3-coder-30b').lane,
        ClaudeBrowserLane.cdp,
      );
    });
  });

  group('running a seat model locally', () {
    test('drops the relay prefix, because `claude --model claude:opus` names '
        'no model Claude Code knows', () {
      expect(claudeLocalModel('claude:opus'), 'opus');
      expect(claudeLocalModel('claude:sonnet'), 'sonnet');
    });

    test('leaves a bare model alone', () {
      expect(claudeLocalModel('opus'), 'opus');
    });

    test('drops every relay variable, so no leftover credential can send the '
        'turn back through the grid', () {
      expect(kClaudeRelayEnvKeys, contains('ANTHROPIC_BASE_URL'));
      expect(kClaudeRelayEnvKeys, contains('ANTHROPIC_AUTH_TOKEN'));
      expect(kClaudeRelayEnvKeys, contains('ANTHROPIC_API_KEY'));
      expect(kClaudeRelayEnvKeys, contains('ANTHROPIC_DEFAULT_OPUS_MODEL'));
    });
  });

  group('the argv a browser turn carries', () {
    test('adds --chrome only when the turn is on the extension lane, since it '
        'costs context on every turn that carries it', () {
      expect(claudeExecArgs(model: 'opus', chrome: true), contains('--chrome'));
      expect(claudeExecArgs(model: 'opus'), isNot(contains('--chrome')));
    });
  });

  group('reading a Claude Code build', () {
    test('takes --chrome from the help text rather than from a version, which '
        'would shut the lane on builds that have the flag', () {
      expect(
        claudeHelpNamesChrome('  --chrome  Enable Claude in Chrome'),
        true,
      );
      expect(claudeHelpNamesChrome('  --agent <agent>  Agent'), false);
    });
  });

  group('the browser MCP entry', () {
    test(
      'runs the published server against the endpoint the app is holding',
      () {
        final entry = chromeDevtoolsEntry(
          npxPath: '/usr/local/bin/npx',
          browserUrl: 'http://127.0.0.1:9222',
        );
        expect(entry['command'], '/usr/local/bin/npx');
        expect(entry['args'], contains('--browser-url'));
        expect(entry['args'], contains('http://127.0.0.1:9222'));
      },
    );
  });

  group('reading the servers a turn opened with', () {
    test('a pending browser server is caught, because a turn can carry '
        '--chrome and still hold no browser tools', () {
      final statuses = claudeServerStatuses(const [
        {'name': 'claude-in-chrome', 'status': 'pending'},
        {'name': 'gitnexus', 'status': 'connected'},
      ]);
      expect(statuses[kClaudeInChromeServer], 'pending');
    });

    test('an entry with no name is skipped rather than fatal — the stream '
        'shifts between releases', () {
      expect(
        claudeServerStatuses(const [
          {'status': 'connected'},
          {'name': 'claude-in-chrome', 'status': 'connected'},
        ]),
        {kClaudeInChromeServer: 'connected'},
      );
    });

    test('a shape the parser does not know yields nothing at all', () {
      expect(claudeServerStatuses('not a list'), isEmpty);
    });
  });

  group('what the activity feed says about a browser step', () {
    test('reads as a browser action, not as an MCP tool name', () {
      expect(
        claudeToolLabel('mcp__claude-in-chrome__navigate_page', const {
          'url': 'https://example.com',
        }),
        'Browser · navigate page · https://example.com',
      );
    });

    test('the app\'s own browser gets the same wording as the extension, so a '
        'user never has to learn which lane ran', () {
      expect(
        claudeToolLabel('mcp__chrome-devtools__click', const {'uid': 'btn-2'}),
        'Browser · click · btn-2',
      );
    });

    test('a browser step is a web step in the feed, not a generic tool', () {
      expect(
        claudeToolKind('mcp__claude-in-chrome__read_page'),
        AgentActivityKind.web,
      );
      expect(
        claudeToolKind('mcp__github__create_issue'),
        isNot(AgentActivityKind.web),
      );
    });
  });
}
