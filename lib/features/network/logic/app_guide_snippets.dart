/// Copy-ready configuration snippets that point an OpenAI-compatible client at a
/// grid. Pure string builders (no I/O) so they're unit-tested once and reused by
/// both the app-guide dialog and the "Apply for me" configurator. Each takes the
/// grid's real relay BASE_URL / API_KEY — the same pair `grid info --env` prints.
library;

/// The model id the ready-made snippets wire up. A sane default most grids
/// serve; the user can swap it for any model their grid actually runs.
const kGuideDefaultModel = 'qwen3-coder';

/// Shell exports of the OpenAI-compatible pair — the generic form any client
/// reads from the environment.
String envSnippet(String base, String key) =>
    'export OPENAI_BASE_URL="$base"\n'
    'export OPENAI_API_KEY="$key"';

/// The `~/.openclaw/openclaw.json` provider block wiring Grid in as a model
/// provider (and a default model for a fresh install). `models.mode: "merge"`
/// appends Grid to OpenClaw's built-in providers instead of replacing them —
/// required per the OpenClaw model-providers docs.
String openClawSnippet(String base, String key) => '{\n'
    '  "agents": { "defaults": { "model": { "primary": "grid/$kGuideDefaultModel" } } },\n'
    '  "models": {\n'
    '    "mode": "merge",\n'
    '    "providers": {\n'
    '      "grid": {\n'
    '        "baseUrl": "$base",\n'
    '        "apiKey": "$key",\n'
    '        "api": "openai-completions",\n'
    '        "models": [{ "id": "$kGuideDefaultModel", "name": "Qwen3 Coder (via Grid)" }]\n'
    '      }\n'
    '    }\n'
    '  }\n'
    '}';

/// The `~/.hermes/config.yaml` endpoint block. `provider: custom` + `base_url`
/// is the documented way to route Hermes at an OpenAI-compatible endpoint; the
/// `model` sub-key names which model to request. Hermes reads the key from
/// `.env` — see [hermesEnvSnippet].
String hermesConfigSnippet(String base) => 'model:\n'
    '  provider: custom\n'
    '  model: $kGuideDefaultModel\n'
    '  base_url: $base';

/// One-liner that appends the API key to `~/.hermes/.env`.
String hermesEnvSnippet(String key) =>
    "echo 'OPENAI_API_KEY=$key' >> ~/.hermes/.env";

/// A minimal OpenAI-SDK example for "any app of your own".
String pythonSnippet(String base, String key) => 'from openai import OpenAI\n'
    '\n'
    'client = OpenAI(base_url="$base", api_key="$key")\n'
    'client.chat.completions.create(\n'
    '    model="$kGuideDefaultModel",                # routed to a matching engine automatically\n'
    '    messages=[{"role": "user", "content": "hello"}],\n'
    ')';
