/// Copy-ready configuration snippets that point an OpenAI-compatible client at a
/// grid. Pure string builders (no I/O) so they're unit-tested once and reused by
/// both the app-guide dialog and the "Apply for me" configurator. Each takes the
/// grid's real relay BASE_URL / API_KEY — the same pair `grid info --env` prints.
library;

/// Fallback model id used only when the grid advertises none (no engine online /
/// relay unreachable). The live model the grid actually serves is preferred — see
/// `networkModelsProvider`; this is just so the snippets are never blank.
const kGuideDefaultModel = 'qwen3-coder';

/// Output-token cap written into Hermes's config. The grid relay rejects any
/// request whose `max_tokens` exceeds 64000; left unset, Hermes derives a far
/// larger value from the model's advertised context and the request 400s — then
/// death-loops into context compression (NousResearch/hermes-agent#55546). Pin
/// it well under the cap. Read by Hermes at `model.max_tokens` (agent_init.py).
const kHermesMaxTokens = 32768;

/// Shell exports of the OpenAI-compatible pair — the generic form any client
/// reads from the environment.
String envSnippet(String base, String key) =>
    'export OPENAI_BASE_URL="$base"\n'
    'export OPENAI_API_KEY="$key"';

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

/// The `~/.hermes/config.yaml` `model:` block that points Hermes at a grid.
/// `provider: custom` + `base_url`/`api_key` route it at the grid's
/// OpenAI-compatible relay and `default` names [model] as the model to request.
/// `max_tokens` is pinned so Hermes stays under the relay's output cap (see
/// [kHermesMaxTokens]). Hermes reads it all here — no `.env`.
String hermesConfigSnippet(String base, String key, String model) => 'model:\n'
    '  provider: custom\n'
    '  base_url: $base\n'
    '  api_key: $key\n'
    '  default: $model\n'
    '  max_tokens: $kHermesMaxTokens';

/// A minimal OpenAI-SDK example for "any app of your own".
String pythonSnippet(String base, String key, String model) =>
    'from openai import OpenAI\n'
    '\n'
    'client = OpenAI(base_url="$base", api_key="$key")\n'
    'client.chat.completions.create(\n'
    '    model="$model",                # routed to a matching engine automatically\n'
    '    messages=[{"role": "user", "content": "hello"}],\n'
    ')';
