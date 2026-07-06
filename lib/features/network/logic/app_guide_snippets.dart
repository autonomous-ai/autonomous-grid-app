/// Copy-ready configuration snippets that point an OpenAI-compatible client at a
/// grid. Pure string builders (no I/O) so they're unit-tested once and reused by
/// both the app-guide dialog and the "Apply for me" configurator. Each takes the
/// grid's real relay BASE_URL / API_KEY — the same pair `grid info --env` prints.
library;

/// Fallback model id used only when the grid advertises none (no engine online /
/// relay unreachable). The live model the grid actually serves is preferred — see
/// `networkModelsProvider`; this is just so the snippets are never blank.
const kGuideDefaultModel = 'qwen3-coder';

/// Output-token cap written into Hermes's `model.max_tokens` (Hermes reads it
/// there; `custom_providers` ignores the field). 64K = 64×1024.
const kHermesMaxTokens = 64000;

/// The `~/.openclaw/openclaw.json` provider block wiring Grid in as a model
/// provider (and [model] as the default for a fresh install). `models.mode:
/// "merge"` appends Grid to OpenClaw's built-in providers instead of replacing
/// them — required per the OpenClaw model-providers docs.
String openClawSnippet(String base, String key, String model) => '{\n'
    '  "agents": { "defaults": { "model": { "primary": "grid/$model" } } },\n'
    '  "models": {\n'
    '    "mode": "merge",\n'
    '    "providers": {\n'
    '      "grid": {\n'
    '        "baseUrl": "$base",\n'
    '        "apiKey": "$key",\n'
    '        "api": "openai-completions",\n'
    '        "models": [{ "id": "$model", "name": "$model (via Grid)" }]\n'
    '      }\n'
    '    }\n'
    '  }\n'
    '}';

/// The Hermes `custom_providers` name for a grid — its relay host (e.g.
/// `grid.autonomous.ai`), so the grid registers as a named provider in Hermes's
/// model picker. Falls back to the brand host if [base] can't be parsed.
String hermesProviderName(String base) =>
    Uri.tryParse(base)?.host ?? 'grid.autonomous.ai';

/// The `~/.hermes/config.yaml` blocks that point Hermes at a grid: the active
/// `model:` selection (`provider: custom` + `base_url`/`api_key`, the `default`
/// model, and a `max_tokens` cap — see [kHermesMaxTokens]) plus a
/// `custom_providers` entry registering the grid as a named provider. Hermes
/// reads it all here — no `.env`.
String hermesConfigSnippet(String base, String key, String model) => 'model:\n'
    '  provider: custom\n'
    '  base_url: $base\n'
    '  api_key: $key\n'
    '  default: $model\n'
    '  max_tokens: $kHermesMaxTokens\n'
    'custom_providers:\n'
    '  - name: ${hermesProviderName(base)}\n'
    '    base_url: $base\n'
    '    api_key: $key\n'
    '    model: $model';

/// A minimal OpenAI-SDK example for "any app of your own".
String pythonSnippet(String base, String key, String model) =>
    'from openai import OpenAI\n'
    '\n'
    'client = OpenAI(base_url="$base", api_key="$key")\n'
    'client.chat.completions.create(\n'
    '    model="$model",                # routed to a matching engine automatically\n'
    '    messages=[{"role": "user", "content": "hello"}],\n'
    ')';
