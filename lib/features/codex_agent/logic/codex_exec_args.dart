import '../../../infrastructure/state/models/network_credential.dart';

/// Environment variable codex reads the grid API key from. Passed via the
/// process environment (never argv), so the token stays out of the command log
/// and shell history — the same discipline `GridCliService.start` uses for the
/// API-engine key.
const String gridApiKeyEnv = 'GRID_API_KEY';

/// Codex config-provider id for the grid relay.
const String _providerId = 'grid';

/// Builds the `codex exec --json` argument list and process environment that
/// point codex at a grid model over the relay.
///
/// Codex ≥ 0.141 speaks only the OpenAI Responses API, so the provider is
/// pinned to `wire_api = "responses"`; the relay serves that once the backend
/// adds `/v1/responses` (until then codex surfaces a 404, humanized by the
/// sender). The agent is locked to `read-only` sandbox with approvals off so it
/// can never mutate the user's disk from a chat box.
({List<String> args, Map<String, String> env}) buildCodexExecArgs({
  required NetworkCredential network,
  required String model,
  required String prompt,
}) {
  final args = <String>[
    'exec',
    '--json',
    '--skip-git-repo-check',
    '--sandbox',
    'read-only',
    '-c',
    'model_provider="$_providerId"',
    '-c',
    'model_providers.$_providerId.name="Grid"',
    '-c',
    'model_providers.$_providerId.base_url="${network.relayBaseUrl}"',
    '-c',
    'model_providers.$_providerId.env_key="$gridApiKeyEnv"',
    '-c',
    'model_providers.$_providerId.wire_api="responses"',
    '-c',
    'approval_policy="never"',
    '-m',
    model,
    prompt,
  ];
  return (args: args, env: {gridApiKeyEnv: network.relayApiKey});
}
