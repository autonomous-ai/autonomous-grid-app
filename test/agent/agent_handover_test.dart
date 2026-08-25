import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_handover.dart';
import 'package:grid_app/features/chat/logic/import/parsed_session.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

ParsedSession session(List<ChatMessage> messages) => ParsedSession(
  agent: ImportedAgent.claude,
  sessionId: 'sess-1',
  title: 'Fixing the parser',
  messages: messages,
  startedAt: DateTime.utc(2026, 8, 25, 9),
  updatedAt: DateTime.utc(2026, 8, 25, 10),
);

ChatMessage user(String text) => ChatMessage(role: ChatRole.user, text: text);
ChatMessage assistant(String text) =>
    ChatMessage(role: ChatRole.assistant, text: text);

void main() {
  group('handing a conversation to the agent taking over', () {
    test('the whole exchange goes across, labelled by who said it — an agent '
        'that cannot tell the user apart from its predecessor answers the '
        'wrong half', () {
      final text = renderAgentHandover(
        session: session([user('rename the parser'), assistant('renamed it')]),
        from: AgentTool.claude,
      );

      expect(text, contains('Me: rename the parser'));
      expect(text, contains('Claude Code: renamed it'));
    });

    test('it opens in the user\'s own voice, because it lands in the user\'s '
        'prompt and it is their Enter that sends it', () {
      final text = renderAgentHandover(
        session: session([user('hello')]),
        from: AgentTool.claude,
      );

      expect(
        text,
        startsWith(
          'Here is the conversation I was just having '
          'with Claude Code',
        ),
      );
    });

    test('a chat too long to hand over keeps its end, not its beginning — the '
        'next sentence follows from where it stopped', () {
      final text = renderAgentHandover(
        session: session([
          user('the oldest thing I said'),
          assistant('a very old answer'),
          user('the newest thing I said'),
        ]),
        from: AgentTool.claude,
        maxChars: 60,
      );

      expect(text, contains('the newest thing I said'));
      expect(text, isNot(contains('the oldest thing I said')));
    });

    test('what was left behind is stated rather than dropped quietly, so the '
        'agent can ask for the part it is missing', () {
      final text = renderAgentHandover(
        session: session([
          user('one'),
          assistant('two'),
          user('three'),
          assistant('four'),
        ]),
        from: AgentTool.codex,
        maxChars: 40,
      );

      expect(text, contains('3 of 4 messages'));
      expect(text, contains('Ask me if you need the earlier ones'));
    });

    test('nothing is cut mid-sentence: a block either goes whole or not at '
        'all, so the transcript never reads as corrupt', () {
      final text = renderAgentHandover(
        session: session([user('aaaa'), assistant('bbbbbbbbbb')]),
        from: AgentTool.claude,
        maxChars: 200,
      );

      expect(text, contains('Claude Code: bbbbbbbbbb'));
      expect(text, contains('Me: aaaa'));
    });

    test('an empty message carries nothing across — a turn that was only a '
        'picture would otherwise hand over a speaker label and no words', () {
      final text = renderAgentHandover(
        session: session([user('   '), assistant('the answer')]),
        from: AgentTool.claude,
      );

      expect(text, isNot(contains('Me:')));
      expect(text, contains('Claude Code: the answer'));
    });
  });
}
