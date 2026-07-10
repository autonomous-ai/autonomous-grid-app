import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/codex_exec_args.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _credential() => const NetworkCredential(
  networkId: 'grid-1',
  name: 'Test grid',
  networkType: 'permissioned-providers',
  lanSignalingUrl: 'https://grid.example/grid-1',
  accessToken: 'secret-token',
  refreshToken: '',
  email: '',
  nodeId: '',
  deviceId: '',
  roles: [],
  scopes: [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

void main() {
  group('buildCodexExecArgs', () {
    final built = buildCodexExecArgs(
      network: _credential(),
      model: 'qwen/qwen3.6-27b',
      prompt: 'read notes.txt',
    );

    test('runs codex exec in JSON mode', () {
      expect(built.args.take(2), ['exec', '--json']);
    });

    test('pins the grid provider at the relay base url', () {
      expect(
        built.args,
        contains(
          'model_providers.grid.base_url='
          '"https://grid.example/grid-1/relay/v1"',
        ),
      );
      expect(built.args, contains('model_provider="grid"'));
    });

    test('uses the Responses wire api codex requires', () {
      expect(built.args, contains('model_providers.grid.wire_api="responses"'));
    });

    test('locks the agent to a read-only sandbox with approvals off', () {
      expect(built.args, containsAllInOrder(['--sandbox', 'read-only']));
      expect(built.args, contains('approval_policy="never"'));
    });

    test('passes the model and prompt through', () {
      expect(built.args, containsAllInOrder(['-m', 'qwen/qwen3.6-27b']));
      expect(built.args.last, 'read notes.txt');
    });

    test('carries the api key in the environment, never in argv', () {
      expect(built.env[gridApiKeyEnv], 'secret-token');
      expect(built.args, isNot(contains('secret-token')));
      expect(
        built.args,
        contains('model_providers.grid.env_key="$gridApiKeyEnv"'),
      );
    });
  });
}
