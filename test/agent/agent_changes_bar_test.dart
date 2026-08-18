import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_changes.dart';
import 'package:grid_app/features/agents/logic/agent_chat_scope.dart';

/// The bar summarising the agent's edits is a transient notice, not a fixture:
/// these pin the ways it should leave the screen — a hand dismiss, the auto-hide
/// countdown, and opening another conversation — while proving none of them
/// throws away the undo the bar is a shortcut to, and that the chat that made the
/// changes still has them waiting on the way back.
void main() {
  ProviderContainer container({
    Duration autoHide = const Duration(seconds: 10),
    String chatId = 'chat-1',
  }) {
    final c = ProviderContainer(
      overrides: [agentChangesAutoHideProvider.overrideWithValue(autoHide)],
    );
    addTearDown(c.dispose);
    c.read(agentChatScopeProvider.notifier).show(chatId);
    c.read(agentChangesProvider.notifier).beginTurn(chatId);
    // Read the bar so its listener on the change list is live before any edit.
    c.read(agentChangesBarProvider);
    return c;
  }

  // Let the bar's listener flush after a change to the underlying list.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  List<AgentChange> changesIn(ProviderContainer c, String chatId) =>
      c.read(agentChangesProvider)[chatId] ?? const [];

  test('stays hidden until the agent actually changes a file', () {
    final c = container();
    expect(c.read(agentChangesBarProvider), isFalse);
  });

  test('shows once the agent records a change', () async {
    final c = container();
    c
        .read(agentChangesProvider.notifier)
        .record(
          chatId: 'chat-1',
          path: '/tmp/a.txt',
          before: 'old',
          after: 'new',
        );
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);
  });

  test('dismiss hides the bar but keeps the change, so a later edit '
      'brings it back over the whole set', () async {
    final c = container();
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(
      chatId: 'chat-1',
      path: '/tmp/a.txt',
      before: 'old',
      after: 'new',
    );
    await settle();

    c.read(agentChangesBarProvider.notifier).dismiss();
    expect(c.read(agentChangesBarProvider), isFalse);
    // The snapshot is still there — hiding is not undoing.
    expect(changesIn(c, 'chat-1'), hasLength(1));

    changes.record(
      chatId: 'chat-1',
      path: '/tmp/b.txt',
      before: 'x',
      after: 'y',
    );
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);
    expect(changesIn(c, 'chat-1'), hasLength(2));
  });

  test('hides itself once the auto-hide delay passes, leaving the undo '
      'data intact', () async {
    final c = container(autoHide: const Duration(milliseconds: 30));
    c
        .read(agentChangesProvider.notifier)
        .record(
          chatId: 'chat-1',
          path: '/tmp/a.txt',
          before: 'old',
          after: 'new',
        );
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(c.read(agentChangesBarProvider), isFalse);
    expect(changesIn(c, 'chat-1'), hasLength(1));
  });

  test('another conversation never shows the bar for changes it did not make, '
      'and coming back to the one that did raises it again', () async {
    final c = container();
    c
        .read(agentChangesProvider.notifier)
        .record(
          chatId: 'chat-1',
          path: '/tmp/a.txt',
          before: 'old',
          after: 'new',
        );
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);

    c.read(agentChatScopeProvider.notifier).show('chat-2');
    await settle();
    expect(c.read(agentChangesBarProvider), isFalse);
    // Leaving the chat hides the notice, it doesn't drop the undo behind it.
    expect(changesIn(c, 'chat-1'), hasLength(1));

    c.read(agentChatScopeProvider.notifier).show('chat-1');
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);
  });

  test(
    'an agent still working for another chat leaves the open one quiet',
    () async {
      final c = container(chatId: 'chat-2');
      // The turn that is running belongs to the chat the user just left.
      c.read(agentChangesProvider.notifier).beginTurn('chat-1');

      c
          .read(agentChangesProvider.notifier)
          .record(
            chatId: 'chat-1',
            path: '/tmp/a.txt',
            before: 'old',
            after: 'new',
          );
      await settle();

      expect(c.read(agentChangesBarProvider), isFalse);
      expect(changesIn(c, 'chat-1'), hasLength(1));
    },
  );
}
