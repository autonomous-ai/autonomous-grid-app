import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_permission_decision.dart';
import 'package:grid_app/features/agents/logic/agent_permissions.dart';
import 'package:grid_app/features/agents/logic/agent_session_grants.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

const _options = <HermesPermissionOption>[
  (optionId: 'allow_once', kind: 'allow_once'),
  (optionId: 'allow_session', kind: 'allow_always'),
  (optionId: 'deny', kind: 'reject_once'),
];

AgentPermission _command() => const AgentPermission(
  id: 7,
  kind: AgentPermissionKind.command,
  summary: 'Delete the build folder',
  command: 'rm -rf build',
  options: _options,
);

ProviderContainer _container({Duration timeout = const Duration(seconds: 55)}) {
  final container = ProviderContainer(
    overrides: [agentPermissionTimeoutProvider.overrideWithValue(timeout)],
  );
  addTearDown(container.dispose);
  return container;
}

/// A [Ref] into the container under test — the shared decision takes one the
/// way a sender hands it its own.
final _refProvider = Provider<Ref>((ref) => ref);

/// The chat under test. Requests are keyed by conversation, so every call names
/// the chat it belongs to.
const _chat = 'chat-1';

void main() {
  test('nothing is pending until the agent asks', () {
    expect(_container().read(agentPermissionProvider(_chat)), isNull);
  });

  test('an allow sends the option the agent offered, and clears the ask', () {
    final container = _container();
    final answers = <String?>[];
    final controller = container.read(agentPermissionsProvider.notifier);

    controller.ask(_chat, _command(), answers.add);
    expect(
      container.read(agentPermissionProvider(_chat))?.command,
      'rm -rf build',
    );

    controller.answer(_chat, AgentPermissionChoice.allowOnce);

    expect(answers, ['allow_once']);
    expect(container.read(agentPermissionProvider(_chat)), isNull);
  });

  test('"allow in this chat" grants the session, not forever', () {
    final container = _container();
    final answers = <String?>[];

    container.read(agentPermissionsProvider.notifier)
      ..ask(_chat, _command(), answers.add)
      ..answer(_chat, AgentPermissionChoice.allowForChat);

    expect(answers, ['allow_session']);
  });

  test('a refusal is sent and left in the activity feed — the user can see the '
      'agent tried and was told no', () {
    final container = _container();
    final answers = <String?>[];

    container.read(agentPermissionsProvider.notifier)
      ..ask(_chat, _command(), answers.add)
      ..answer(_chat, AgentPermissionChoice.refuse);

    expect(answers, ['deny']);
    final steps = container.read(agentRunProvider(_chat)).steps;
    expect(steps.single.label, contains('rm -rf build'));
    expect(steps.single.status, AgentActivityStatus.failed);
  });

  test(
    'no answer at all is a no — the card never becomes a dead button',
    () async {
      final container = _container(timeout: const Duration(milliseconds: 10));
      final answers = <String?>[];

      container
          .read(agentPermissionsProvider.notifier)
          .ask(_chat, _command(), answers.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(answers, ['deny']);
      expect(container.read(agentPermissionProvider(_chat)), isNull);
    },
  );

  test('two chats can be waiting at once — answering one leaves the other '
      'asking, rather than dropping the way back to its agent', () {
    final container = _container();
    final first = <String?>[];
    final second = <String?>[];
    final controller = container.read(agentPermissionsProvider.notifier);

    controller.ask('chat-1', _command(), first.add);
    controller.ask('chat-2', _command(), second.add);
    controller.answer('chat-1', AgentPermissionChoice.allowOnce);

    expect(first, ['allow_once']);
    expect(second, isEmpty);
    expect(container.read(agentPermissionProvider('chat-1')), isNull);
    expect(
      container.read(agentPermissionProvider('chat-2'))?.command,
      'rm -rf build',
      reason: "the second chat's agent is still waiting on its own answer",
    );

    controller.answer('chat-2', AgentPermissionChoice.refuse);
    expect(second, ['deny']);
  });

  test('when the turn ends the ask goes away, unanswered', () {
    final container = _container();
    final answers = <String?>[];
    final controller = container.read(agentPermissionsProvider.notifier);

    controller.ask(_chat, _command(), answers.add);
    controller.clear(_chat);

    expect(container.read(agentPermissionProvider(_chat)), isNull);
    expect(answers, isEmpty, reason: 'a dead session has nothing to answer');
    // And a late tap on a card that is already gone does nothing.
    controller.answer(_chat, AgentPermissionChoice.allowOnce);
    expect(answers, isEmpty);
  });

  group('one policy for every agent that can ask', () {
    /// Run the shared decision, collecting whatever it answers the agent.
    List<String?> decide(
      ProviderContainer container,
      AgentApprovalMode mode, {
      String? grantKey,
      AgentPermission? request,
    }) {
      final answers = <String?>[];
      container.read(agentRunsProvider.notifier);
      decideAgentPermission(
        ref: container.read(_refProvider),
        agent: 'test',
        chat: _chat,
        request: request ?? _command(),
        approval: mode,
        grantKey: grantKey,
        answer: answers.add,
      );
      return answers;
    }

    test('look-dont-touch answers no itself, and the user is never '
        'interrupted for a command that was never going to run', () {
      final container = _container();
      expect(decide(container, AgentApprovalMode.readOnly), ['deny']);
      expect(container.read(agentPermissionProvider(_chat)), isNull);
    });

    test('full access answers yes once — never the agent\'s own "always", '
        'which would outlive the mode the user picked', () {
      final container = _container();
      expect(decide(container, AgentApprovalMode.full), ['allow_once']);
      expect(container.read(agentPermissionProvider(_chat)), isNull);
    });

    test('ask-first stops and puts it to the user, and nothing is answered '
        'until they say so', () {
      final container = _container();
      expect(decide(container, AgentApprovalMode.ask), isEmpty);
      expect(container.read(agentPermissionProvider(_chat)), isNotNull);
    });

    test(
      'a yes for the whole chat is remembered, so the same command is not '
      'asked about twice — for a transport that cannot remember it itself',
      () {
        final container = _container();
        decide(
          container,
          AgentApprovalMode.ask,
          grantKey: 'command:rm -rf build',
        );
        container
            .read(agentPermissionsProvider.notifier)
            .answer(_chat, AgentPermissionChoice.allowForChat);

        // The same command again: answered outright, no second card.
        final again = decide(
          container,
          AgentApprovalMode.ask,
          grantKey: 'command:rm -rf build',
        );
        expect(again, ['allow_once']);
        expect(container.read(agentPermissionProvider(_chat)), isNull);
      },
    );

    test('agreeing to one command does not agree to another', () {
      final container = _container();
      decide(container, AgentApprovalMode.ask, grantKey: 'command:ls');
      container
          .read(agentPermissionsProvider.notifier)
          .answer(_chat, AgentPermissionChoice.allowForChat);
      expect(
        decide(container, AgentApprovalMode.ask, grantKey: 'command:rm -rf /'),
        isEmpty,
      );
      expect(container.read(agentPermissionProvider(_chat)), isNotNull);
    });

    test('a chat starting over carries none of its own standing yeses', () {
      final container = _container();
      final grants = container.read(agentSessionGrantsProvider.notifier)
        ..grant(_chat, 'command:ls');
      expect(grants.holds(_chat, 'command:ls'), isTrue);
      grants.clear(_chat);
      expect(grants.holds(_chat, 'command:ls'), isFalse);
    });
  });
}
