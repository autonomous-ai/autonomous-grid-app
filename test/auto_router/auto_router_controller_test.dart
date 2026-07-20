import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/auto_router/logic/auto_router_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _grid = 'grid-1';
const _setAdvisors = [
  'router',
  'set-advisors',
  'openai',
  '--grid',
  _grid,
  '--json',
];
const _enable = ['router', 'enable', '--grid', _grid, '--json'];

NetworkCredential _network({required bool owner}) => NetworkCredential(
  networkId: _grid,
  name: 'Grid',
  networkType: 'permissioned-public',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node',
  deviceId: 'dev',
  roles: owner ? const ['admin'] : const ['consumer'],
  scopes: const [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// A [SelectedNetwork] pinned to a fixed grid, so the controller resolves an
/// owner (or not) without wiring the session/prefs/store providers.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}

/// A [FakeGridCliService] that records every command, so tests can assert which
/// router mutations ran (or didn't).
class _RecordingCli extends FakeGridCliService {
  final List<List<String>> runs = [];
  @override
  Future<CliResult> run(List<String> args) {
    runs.add(args);
    return super.run(args);
  }
}

CliResult _ok(String stdout) =>
    CliResult(exitCode: 0, stdout: stdout, stderr: '');

/// A CLI whose router status returns [statusJson]; the catalog and both
/// mutations always succeed, so an auto-enable can run end to end.
_RecordingCli _cli(String statusJson) {
  final cli = _RecordingCli()
    ..stubResult(const [
      'router',
      'status',
      '--grid',
      _grid,
      '--json',
    ], _ok(statusJson))
    ..stubResult(
      const ['router', 'models', '--json'],
      _ok(
        '{"providers":[{"provider":"openai","default_model":"gpt-4.1-mini",'
        '"models":["gpt-4.1-mini"]}]}',
      ),
    )
    ..stubResult(_setAdvisors, _ok('{"synced": true}'))
    ..stubResult(_enable, _ok('{"synced": true}'));
  return cli;
}

ProviderContainer _container(NetworkCredential? network, GridCliService cli) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      selectedNetworkProvider.overrideWith(
        () => _FixedSelectedNetwork(network),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  const fresh = '{"enabled": false, "advisors": []}';
  const enabled = '{"enabled": true, "advisors": [{"provider": "openai"}]}';
  const disabledWithAdvisors =
      '{"enabled": false, "advisors": [{"provider": "openai"}]}';

  test(
    'auto-enables a fresh grid for the owner: set-advisors then enable',
    () async {
      final cli = _cli(fresh);
      final container = _container(_network(owner: true), cli);
      final controller = container.read(autoRouterControllerProvider.notifier);
      await container.read(autoRouterControllerProvider.future);

      await controller.autoEnableForOwner();

      expect(cli.runs, contains(equals(_setAdvisors)));
      expect(cli.runs, contains(equals(_enable)));
    },
  );

  test('does not auto-enable for a non-owner', () async {
    final cli = _cli(fresh);
    final container = _container(_network(owner: false), cli);
    final controller = container.read(autoRouterControllerProvider.notifier);
    await container.read(autoRouterControllerProvider.future);

    await controller.autoEnableForOwner();

    expect(cli.runs, isNot(contains(equals(_setAdvisors))));
    expect(cli.runs, isNot(contains(equals(_enable))));
  });

  test('leaves an already-enabled grid untouched', () async {
    final cli = _cli(enabled);
    final container = _container(_network(owner: true), cli);
    final controller = container.read(autoRouterControllerProvider.notifier);
    await container.read(autoRouterControllerProvider.future);
    cli.runs.clear();

    await controller.autoEnableForOwner();

    expect(cli.runs, isEmpty);
  });

  test(
    'respects a grid the owner turned off (advisors set, disabled)',
    () async {
      final cli = _cli(disabledWithAdvisors);
      final container = _container(_network(owner: true), cli);
      final controller = container.read(autoRouterControllerProvider.notifier);
      await container.read(autoRouterControllerProvider.future);
      cli.runs.clear();

      await controller.autoEnableForOwner();

      expect(cli.runs, isEmpty);
    },
  );

  test('auto-enables at most once per grid', () async {
    final cli = _cli(fresh);
    final container = _container(_network(owner: true), cli);
    final controller = container.read(autoRouterControllerProvider.notifier);
    await container.read(autoRouterControllerProvider.future);

    await controller.autoEnableForOwner();
    await controller.autoEnableForOwner();

    final enables = cli.runs.where((r) => r.join(' ') == _enable.join(' '));
    expect(enables.length, 1, reason: 'the per-grid guard blocks a repeat');
  });
}
