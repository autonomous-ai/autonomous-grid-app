import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/delete_network_controller.dart';
import 'package:grid_app/infrastructure/api/managed_network_client.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

const _net = 'net-1';
const _syncArgs = ['sync'];

ManagedNetworkDeleteFn _stubDelete((bool, ManagedNetworkError?) result) {
  return ({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
  }) async => result;
}

/// A [FakeGridCliService] that records the commands it's asked to run.
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];

  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

ProviderContainer _container({
  required ManagedNetworkDeleteFn delete,
  GridCliService? cli,
  String? sessionToken = 'tok',
}) {
  final container = ProviderContainer(
    overrides: [
      managedNetworkDeleteProvider.overrideWithValue(delete),
      gridCliServiceProvider.overrideWithValue(cli),
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: const [], sessionToken: sessionToken),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('deletes, syncs the local list, then reports done', () async {
    final container = _container(
      delete: _stubDelete((true, null)),
      cli: FakeGridCliService(),
    );

    final error = await container
        .read(deleteNetworkControllerProvider.notifier)
        .delete(_net);

    expect(error, isNull);
    expect(
      container.read(deleteNetworkControllerProvider),
      isA<DeleteNetworkDone>(),
    );
  });

  test('runs `grid sync` after a successful delete', () async {
    final cli = _RecordingCli();
    final container = _container(delete: _stubDelete((true, null)), cli: cli);

    await container.read(deleteNetworkControllerProvider.notifier).delete(_net);

    expect(cli.runs, contains(equals(_syncArgs)));
  });

  test('surfaces the API error and stays failed', () async {
    final container = _container(
      delete: _stubDelete((
        false,
        const ManagedNetworkError('Only the grid owner can delete this grid.'),
      )),
      cli: FakeGridCliService(),
    );

    final error = await container
        .read(deleteNetworkControllerProvider.notifier)
        .delete(_net);

    expect(error, contains('owner'));
    final state = container.read(deleteNetworkControllerProvider);
    expect(state, isA<DeleteNetworkFailed>());
    expect((state as DeleteNetworkFailed).message, contains('owner'));
  });

  test('does not sync when the delete fails', () async {
    final cli = _RecordingCli();
    final container = _container(
      delete: _stubDelete((false, const ManagedNetworkError('nope'))),
      cli: cli,
    );

    await container.read(deleteNetworkControllerProvider.notifier).delete(_net);

    expect(cli.runs, isEmpty);
  });

  test('fails fast when not signed in', () async {
    final container = _container(
      delete: _stubDelete((true, null)),
      cli: FakeGridCliService(),
      sessionToken: null,
    );

    final error = await container
        .read(deleteNetworkControllerProvider.notifier)
        .delete(_net);

    expect(error, isNotNull);
    expect(
      container.read(deleteNetworkControllerProvider),
      isA<DeleteNetworkFailed>(),
    );
  });
}
