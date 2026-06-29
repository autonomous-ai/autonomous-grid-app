import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/enable_provider_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

const _net = 'grid-xyz';
const _email = 'me@x.com';
const _addArgs = [
  'members', 'add', _net, _email, '--role', 'provider',
];
const _syncArgs = ['sync'];

void main() {
  test('grants the provider role, syncs, then reports done', () async {
    final fake = FakeGridCliService()
      ..stubResult(
          _addArgs,
          const CliResult(
              exitCode: 0,
              stdout: 'Added me@x.com (roles: provider)',
              stderr: ''))
      ..stubResult(_syncArgs,
          const CliResult(exitCode: 0, stdout: 'Synced 1 grid(s): xyz.', stderr: ''));
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    final seen = <EnableProviderState>[];
    container.listen(enableProviderControllerProvider, (_, next) => seen.add(next));

    await container
        .read(enableProviderControllerProvider.notifier)
        .enable(networkId: _net, email: _email);

    expect(container.read(enableProviderControllerProvider), isA<EnableDone>());
    expect(seen.whereType<EnableRunning>(), isNotEmpty);
  });

  test('surfaces the members-add failure and never syncs', () async {
    final fake = FakeGridCliService()
      ..stubResult(
          _addArgs,
          const CliResult(
              exitCode: 1, stdout: '', stderr: 'forbidden: not an admin'));
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    await container
        .read(enableProviderControllerProvider.notifier)
        .enable(networkId: _net, email: _email);

    final state = container.read(enableProviderControllerProvider);
    expect(state, isA<EnableFailed>());
    expect((state as EnableFailed).message, contains('forbidden'));
  });

  test('fails fast when grid is absent', () async {
    final container = ProviderContainer(
      overrides: [gridCliServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await container
        .read(enableProviderControllerProvider.notifier)
        .enable(networkId: _net, email: _email);

    expect(
        container.read(enableProviderControllerProvider), isA<EnableFailed>());
  });
}
