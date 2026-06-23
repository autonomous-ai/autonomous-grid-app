import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

const _args = [
  'request', 'chat',
  '--network', 'net',
  '--model', 'm',
  '--message', 'hi',
];

Future<void> _send(ProviderContainer c) =>
    c.read(chatControllerProvider.notifier).send(network: 'net', model: 'm', message: 'hi');

void main() {
  test('appends the user message then the assistant reply on success', () async {
    final fake = FakeGridCliService()
      ..stubResult(_args,
          const CliResult(exitCode: 0, stdout: 'hello there', stderr: ''));
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await _send(container);

    final state = container.read(chatControllerProvider);
    expect(state.sending, isFalse);
    expect(state.error, isNull);
    expect(state.messages.map((m) => m.role).toList(),
        [ChatRole.user, ChatRole.assistant]);
    expect(state.messages.last.text, 'hello there');
  });

  test('surfaces stderr as an error and keeps the user message', () async {
    final fake = FakeGridCliService()
      ..stubResult(_args,
          const CliResult(exitCode: 1, stdout: '', stderr: 'no provider available'));
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await _send(container);

    final state = container.read(chatControllerProvider);
    expect(state.error, contains('no provider'));
    expect(state.messages, hasLength(1));
    expect(state.messages.single.role, ChatRole.user);
  });

  test('fails fast when grid is absent', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await _send(container);

    final state = container.read(chatControllerProvider);
    expect(state.error, isNotNull);
    expect(state.messages, hasLength(1));
  });
}
