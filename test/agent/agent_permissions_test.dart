import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/common/agent_permissions.dart';
import 'package:grid_app/features/agent/common/agent_providers.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/hermes_permission_policy.dart';

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

void main() {
  test('nothing is pending until the agent asks', () {
    expect(_container().read(agentPermissionProvider), isNull);
  });

  test('an allow sends the option the agent offered, and clears the ask', () {
    final container = _container();
    final answers = <String?>[];
    final controller = container.read(agentPermissionProvider.notifier);

    controller.ask(_command(), answers.add);
    expect(container.read(agentPermissionProvider)?.command, 'rm -rf build');

    controller.answer(AgentPermissionChoice.allowOnce);

    expect(answers, ['allow_once']);
    expect(container.read(agentPermissionProvider), isNull);
  });

  test('"allow in this chat" grants the session, not forever', () {
    final container = _container();
    final answers = <String?>[];

    container.read(agentPermissionProvider.notifier)
      ..ask(_command(), answers.add)
      ..answer(AgentPermissionChoice.allowForChat);

    expect(answers, ['allow_session']);
  });

  test('a refusal is sent and left in the activity feed — the user can see the '
      'agent tried and was told no', () {
    final container = _container();
    final answers = <String?>[];

    container.read(agentPermissionProvider.notifier)
      ..ask(_command(), answers.add)
      ..answer(AgentPermissionChoice.refuse);

    expect(answers, ['deny']);
    final steps = container.read(agentActivityProvider);
    expect(steps.single.label, contains('rm -rf build'));
    expect(steps.single.status, AgentActivityStatus.failed);
  });

  test(
    'no answer at all is a no — the card never becomes a dead button',
    () async {
      final container = _container(timeout: const Duration(milliseconds: 10));
      final answers = <String?>[];

      container
          .read(agentPermissionProvider.notifier)
          .ask(_command(), answers.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(answers, ['deny']);
      expect(container.read(agentPermissionProvider), isNull);
    },
  );

  test('when the turn ends the ask goes away, unanswered', () {
    final container = _container();
    final answers = <String?>[];
    final controller = container.read(agentPermissionProvider.notifier);

    controller.ask(_command(), answers.add);
    controller.clear();

    expect(container.read(agentPermissionProvider), isNull);
    expect(answers, isEmpty, reason: 'a dead session has nothing to answer');
    // And a late tap on a card that is already gone does nothing.
    controller.answer(AgentPermissionChoice.allowOnce);
    expect(answers, isEmpty);
  });
}
