import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/claude_permission.dart';
import 'package:grid_app/infrastructure/mcp/grid_browser_tool_permission.dart';

Map<String, dynamic> request(String tool, Map<String, Object?> input) => {
  'type': 'control_request',
  'request_id': 'r1',
  'request': {'subtype': 'can_use_tool', 'tool_name': tool, 'input': input},
};

void main() {
  group('which browser calls stop to ask', () {
    test('looking at the page never interrupts, the way reading a file does '
        'not — one search is three snapshots, and a card for each would bury '
        'the two that matter', () {
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_snapshot'), isTrue);
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_read'), isTrue);
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_screenshot'), isTrue);
    });

    test('acting on the page always asks: this tab is signed in as the user, '
        'so a click can spend their money or send their mail', () {
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_click'), isFalse);
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_type'), isFalse);
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_navigate'), isFalse);
    });

    test('a browser tool added later asks until somebody decides it should '
        'not — the free list is what is named, never what is left over', () {
      expect(gridBrowserToolReadsOnly('mcp__grid__browser_upload'), isFalse);
    });

    test('another server’s tool of the same name is not Grid’s: the prefix is '
        'the whole of what says whose tool this is', () {
      expect(gridBrowserToolReadsOnly('mcp__other__browser_snapshot'), isFalse);
      expect(gridBrowserToolCard('browser_click', const {}), isNull);
    });
  });

  group('what the card asks', () {
    test('a click reads as an act on the page, not as an MCP tool name over a '
        'ref nobody can read', () {
      final permission = parseClaudePermission(
        request('mcp__grid__browser_click', {'ref': 'e12'}),
      )!;

      expect(permission.summary, 'Click something on the page');
      expect(permission.command, isEmpty);
      expect(permission.kind, AgentPermissionKind.other);
    });

    test('typing shows the text, because that is the part worth judging', () {
      final permission = parseClaudePermission(
        request('mcp__grid__browser_type', {
          'ref': 'e4',
          'text': 'my home address',
          'submit': true,
        }),
      )!;

      expect(permission.summary, 'Type on the page and press Enter');
      expect(permission.command, 'my home address');
    });

    test('opening a page shows the address, since where it goes is the whole '
        'question', () {
      final permission = parseClaudePermission(
        request('mcp__grid__browser_navigate', {'url': 'https://bank.example'}),
      )!;

      expect(permission.summary, 'Open a page in the browser');
      expect(permission.command, 'https://bank.example');
    });

    test('a tool Grid does not own still reaches the user as its own name, so '
        'nothing is quietly dressed up as something else', () {
      final permission = parseClaudePermission(
        request('mcp__other__do_thing', {'a': 1}),
      )!;

      expect(permission.summary, 'mcp__other__do_thing');
    });
  });
}
