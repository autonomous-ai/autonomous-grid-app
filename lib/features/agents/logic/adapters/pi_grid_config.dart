import 'dart:convert';

/// The provider id the app's own Pi turns answer through, defined in the run's
/// own `models.json`. Selected on the command line with `--model grid/<model>`.
const String kPiGridProviderId = 'grid';

/// The variable the app's own Pi turns read the grid's key from.
///
/// `models.json` names it as `apiKey: "$GRID_APP_API_KEY"` (an env reference, so
/// no secret is written to disk) and the app sets it per run in the child's
/// environment. Shares the name Codex uses — they run as separate processes, so
/// the value is handed to each afresh and never crosses over.
const String kPiAppApiKeyEnv = 'GRID_APP_API_KEY';

/// The `models.json` that makes a grid Pi's model, written into the run's own
/// **app-owned** Pi config dir (`PI_CODING_AGENT_DIR`) — never the user's
/// `~/.pi/agent/models.json`. It defines the grid as an OpenAI-compatible
/// provider (`api: openai-completions`, so Pi posts to `<base>/chat/completions`
/// — exactly where the app's own chat lands) whose key is an env reference.
///
/// Pure, and unit-tested: a wrong base or key here fails exactly like a model
/// that wouldn't answer (§7).
String piModelsJson({required String base, required String model}) {
  final config = {
    'providers': {
      kPiGridProviderId: {
        'name': 'Grid',
        'baseUrl': base,
        'api': 'openai-completions',
        // An env reference, not the key itself — resolved from the child's
        // environment ([kPiAppApiKeyEnv]) at request time.
        'apiKey': '\$$kPiAppApiKeyEnv',
        'models': [
          {
            'id': model,
            'name': model,
            'reasoning': false,
            'input': ['text'],
            // Generous bookkeeping defaults — the grid, not this file, decides
            // what the model can really take; these only feed Pi's own display.
            'contextWindow': 200000,
            'maxTokens': 8192,
            'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
          },
        ],
      },
    },
  };
  return const JsonEncoder.withIndent('  ').convert(config);
}

/// The `settings.json` for the run's own Pi config dir.
///
/// `defaultProjectTrust: always` is the belt to `--approve`'s brace — a run
/// answers without stopping to ask about the workspace it opens in. When
/// [userSkillsDir] is given, it's added to `skills` so an app-driven turn still
/// loads the skills the user manages in their real `~/.pi/agent/skills` (the
/// Skills screen's `SkillSource.pi`), even though the turn runs in an app-owned
/// config dir.
String piSettingsJson({String? userSkillsDir}) {
  final settings = <String, Object?>{
    'defaultProjectTrust': 'always',
    if (userSkillsDir != null && userSkillsDir.isNotEmpty)
      'skills': [userSkillsDir],
  };
  return const JsonEncoder.withIndent('  ').convert(settings);
}

/// The environment one Pi turn runs with: its app-owned config dir, a stable
/// session dir so `--session <id>` can resume, the grid key the `models.json`
/// references, and `PI_OFFLINE` so an app turn makes no startup network calls.
Map<String, String> piGridEnvironment({
  required String configDir,
  required String sessionDir,
  required String apiKey,
}) => {
  'PI_CODING_AGENT_DIR': configDir,
  'PI_CODING_AGENT_SESSION_DIR': sessionDir,
  kPiAppApiKeyEnv: apiKey,
  'PI_OFFLINE': '1',
};
