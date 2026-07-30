/// Copy-ready configuration snippets that point an OpenAI-compatible client at a
/// grid. Pure string builders (no I/O) so they're unit-tested once and reused by
/// both the app-guide dialog and the "Apply for me" configurator. Each takes the
/// grid's real relay BASE_URL / API_KEY — the same pair `grid info --env` prints.
library;

import 'dart:convert';

import '../../provider_node/logic/api_engine_catalog.dart';
import 'client_app_detector.dart';

/// Environment variable a client app reads the grid's API key from. Kept out of
/// config files (and out of argv) so the token stays clear of shell history and
/// the command log.
const String gridApiKeyEnv = 'GRID_API_KEY';

/// Fallback model id used only when the grid advertises none (no engine online /
/// relay unreachable). The live model the grid actually serves is preferred — see
/// `networkModelsProvider`; this is just so the snippets are never blank.
const kGuideDefaultModel = 'qwen3-coder';

/// Output-token cap written into Hermes's `model.max_tokens` (Hermes reads it
/// there; `custom_providers` ignores the field). 64K = 64×1024.
const kHermesMaxTokens = 64000;

/// Hermes's api-mode (a.k.a. `transport`) value for the OpenAI **Responses API**
/// (`POST /responses`). Written on the grid's `custom_providers` entry for a
/// responses-only model (codex) so Hermes speaks that dialect instead of
/// chat-completions — the equivalent of Codex's `wire_api = "responses"`.
const String kHermesResponsesApiMode = 'codex_responses';

/// Stable `model.provider` selector for the grid's Hermes provider when a
/// responses-only model is in play. A **named** provider is required: Hermes
/// silently downgrades a bare `provider: custom` back to chat-completions on a
/// non-OpenAI host, but honours `api_mode` on a named `custom_providers` entry
/// matched by this `provider_key`. Chat-completions grids keep `provider:
/// custom`, whose base_url trust path needs no named selector.
const String kHermesGridProviderKey = 'grid';

/// The `~/.openclaw/openclaw.json` provider block wiring Grid in as a model
/// provider, listing **every** model the grid serves ([models]) and the first as
/// the default for a fresh install. `models.mode: "merge"` appends Grid to
/// OpenClaw's built-in providers instead of replacing them — required per the
/// OpenClaw model-providers docs. Falls back to the default model id when the
/// grid advertises none (so the block is never empty/invalid).
String openClawSnippet(String base, String key, List<String> models) {
  final ids = models.isEmpty ? const [kGuideDefaultModel] : models;
  final entries = ids
      .map((m) => '          { "id": "$m", "name": "$m (via Grid)" }')
      .join(',\n');
  return '{\n'
      '  "agents": { "defaults": { "model": { "primary": "grid/${ids.first}" } } },\n'
      '  "models": {\n'
      '    "mode": "merge",\n'
      '    "providers": {\n'
      '      "grid": {\n'
      '        "baseUrl": "$base",\n'
      '        "apiKey": "$key",\n'
      '        "api": "openai-completions",\n'
      '        "models": [\n'
      '$entries\n'
      '        ]\n'
      '      }\n'
      '    }\n'
      '  }\n'
      '}';
}

/// The Hermes `custom_providers` name for a grid — its relay host (e.g.
/// `grid.autonomous.ai`), so the grid registers as a named provider in Hermes's
/// model picker. Falls back to the brand host if [base] can't be parsed.
String hermesProviderName(String base) =>
    Uri.tryParse(base)?.host ?? 'grid.autonomous.ai';

/// The `~/.hermes/config.yaml` blocks that point Hermes at a grid: the active
/// `model:` selection (`base_url`/`api_key`, the `default` model, and a
/// `max_tokens` cap — see [kHermesMaxTokens]) plus a `custom_providers` entry
/// registering the grid as a named provider. Hermes reads it all here — no
/// `.env`.
///
/// A responses-only model (codex) needs the Responses dialect, which Hermes only
/// honours on a **named** provider — so those grids select the named entry
/// (`provider: $kHermesGridProviderKey`) and carry `api_mode:
/// $kHermesResponsesApiMode`. A chat-completions grid keeps the simpler bare
/// `provider: custom` + base_url trust path.
String hermesConfigSnippet(String base, String key, String model) {
  final responses = isResponsesOnlyModel(model);
  final buffer = StringBuffer()
    ..write('model:\n')
    ..write('  provider: ${responses ? kHermesGridProviderKey : 'custom'}\n')
    ..write('  base_url: $base\n')
    ..write('  api_key: $key\n')
    ..write('  default: $model\n')
    ..write('  max_tokens: $kHermesMaxTokens\n')
    ..write('custom_providers:\n')
    ..write('  - name: ${hermesProviderName(base)}\n');
  if (responses) buffer.write('    provider_key: $kHermesGridProviderKey\n');
  buffer
    ..write('    base_url: $base\n')
    ..write('    api_key: $key\n')
    ..write('    model: $model');
  if (responses) buffer.write('\n    api_mode: $kHermesResponsesApiMode');
  return buffer.toString();
}

/// Codex `model_providers` id for a grid — the value its `model_provider` key
/// points at, and the table name in the config block.
const String kCodexProviderId = 'grid';

/// The `~/.codex/config.toml` block that makes a grid Codex's model: the grid as
/// a named provider plus `model` / `model_provider` selecting it.
///
/// `wire_api = "responses"` is forced: Codex ≥ 0.141 rejects
/// `wire_api = "chat"` outright ("no longer supported"), so the grid must answer
/// on the Responses API.
/// TODO(BE): Codex only works once the relay serves `/v1/responses` — until then
/// a send fails with a 404 (same wall as the Chat tab's Agent mode).
///
/// Codex has no `api_key` config field — it reads the key from the environment
/// variable named by `env_key` — so the key lives in [codexEnvSnippet], not here.
String codexConfigSnippet(String base, String model) =>
    'model = "$model"\n'
    'model_provider = "$kCodexProviderId"\n'
    '\n'
    '[model_providers.$kCodexProviderId]\n'
    'name = "Grid"\n'
    'base_url = "$base"\n'
    'env_key = "$gridApiKeyEnv"\n'
    'wire_api = "responses"';

/// The `~/.codex/.env` line holding the grid's API key. Codex loads this dotenv
/// itself, so the user never has to export a variable in their shell.
String codexEnvSnippet(String key) => '$gridApiKeyEnv=$key';

/// The variables Claude Code reads a connection from: the endpoint, and the
/// credential it sends as `Authorization: Bearer`.
///
/// `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`: the key variant travels in
/// `x-api-key` and needs a one-time approval in an interactive session before
/// Claude Code will use it, which a "set it up for me" button can't give.
const String kClaudeBaseUrlEnv = 'ANTHROPIC_BASE_URL';
const String kClaudeAuthTokenEnv = 'ANTHROPIC_AUTH_TOKEN';

/// The `env` block Claude Code reads its connection from, as it lands in
/// [kClaudeSettingsPath]. One source of truth for both the copy-paste snippet
/// and the "Set up for me" merge.
///
/// A settings file rather than a shell export because that is the only form that
/// reaches every way Claude Code runs (a shell export reaches the terminal it
/// was typed in, and not the background sessions).
///
/// TODO(BE): this only works once the relay serves Anthropic's Messages API
/// (`POST /v1/messages`, streamed as SSE, forwarding `anthropic-version` /
/// `anthropic-beta`) and answers to the Claude model ids Claude Code asks for.
/// Until then the steps end in a connection error — which is what
/// [ClientAppInfo.caveat] says on the panel.
Map<String, Object> claudeCodeSettings(String base, String key) => {
  'env': {kClaudeBaseUrlEnv: base, kClaudeAuthTokenEnv: key},
};

/// The paste-ready `settings.json` block for Claude Code — pretty JSON so it
/// stays valid on a literal paste into an empty file.
String claudeCodeSettingsSnippet(String base, String key) =>
    const JsonEncoder.withIndent('  ').convert(claudeCodeSettings(base, key));

/// Buzz's `provider` value for an OpenAI-compatible endpoint. The desktop
/// translates it to `BUZZ_AGENT_PROVIDER=openai` and reads the `OPENAI_COMPAT_*`
/// pair when it launches `buzz-agent`; a free-text value (e.g. `"Grid"`) makes
/// the agent die at startup with `BUZZ_AGENT_PROVIDER=<x> not supported`.
const String kBuzzProvider = 'openai-compat';

/// The env keys `buzz-agent` reads its connection from — the `OPENAI_COMPAT_*`
/// names, **not** the bare `OPENAI_*` ones (those fail with
/// `OPENAI_COMPAT_API_KEY required`). `kBuzzApiModeEnv` picks the wire dialect:
/// `chat` (chat-completions) or `responses`.
const String kBuzzBaseUrlEnv = 'OPENAI_COMPAT_BASE_URL';
const String kBuzzApiKeyEnv = 'OPENAI_COMPAT_API_KEY';
const String kBuzzApiModeEnv = 'OPENAI_COMPAT_API';

/// Which OpenAI wire dialect Buzz should speak to the grid for [model]: the
/// Responses API for a responses-only model (codex), else chat-completions.
/// Pinned explicitly rather than left to Buzz's `auto`, whose name-based
/// heuristic routes anything containing `gpt-5` to `/responses` — wrong for a
/// chat model that merely has that in its id.
String buzzApiMode(String model) =>
    isResponsesOnlyModel(model) ? 'responses' : 'chat';

/// The `provider` / `model` / `env_vars` map Buzz stores in
/// [kBuzzConfigRelPath] to make a grid the default model for every agent. One
/// source of truth for both the copy-paste block ([buzzGlobalConfigSnippet]) and
/// the "Set up for me" merge ([ClientAppConfigurator]).
Map<String, Object> buzzGlobalConfig(String base, String key, String model) => {
  'provider': kBuzzProvider,
  'model': model,
  'env_vars': {
    kBuzzBaseUrlEnv: base,
    kBuzzApiKeyEnv: key,
    kBuzzApiModeEnv: buzzApiMode(model),
  },
};

/// The paste-ready `global-agent-config.json` for Buzz — pretty JSON so it
/// matches how the desktop writes the file and stays valid on a literal paste.
String buzzGlobalConfigSnippet(String base, String key, String model) =>
    const JsonEncoder.withIndent(
      '  ',
    ).convert(buzzGlobalConfig(base, key, model));

/// The paste-ready blocks for [info]'s manual setup — one per file the app needs
/// (Codex takes two: its config and the dotenv holding the key). Each block
/// carries the [label] + [caption] shown above it, so the panel just renders
/// what the app declares instead of branching per app.
List<({String label, String caption, String code})> appSnippets(
  ClientAppInfo info,
  String base,
  String key,
  List<String> models,
) {
  final model = models.isEmpty ? kGuideDefaultModel : models.first;
  return switch (info.app) {
    // Hermes leads with its in-app flow, so its file is the "prefer files?"
    // alternative rather than the main event.
    ClientApp.hermes => [
      (
        label: 'Prefer editing files?',
        caption: info.configPath,
        code: hermesConfigSnippet(base, key, model),
      ),
    ],
    ClientApp.openClaw => [
      (
        label: info.name,
        caption: 'Paste into ${info.configPath}',
        code: openClawSnippet(base, key, models),
      ),
    ],
    ClientApp.codex => [
      (
        label: info.name,
        caption: 'Paste into ${info.configPath}',
        code: codexConfigSnippet(base, model),
      ),
      (
        label: 'Your API key',
        caption: 'Paste into $kCodexEnvPath',
        code: codexEnvSnippet(key),
      ),
    ],
    ClientApp.claudeCode => [
      (
        label: info.name,
        caption: 'Paste into ${info.configPath}',
        code: claudeCodeSettingsSnippet(base, key),
      ),
    ],
    ClientApp.buzz => [
      (
        label: info.name,
        caption: 'Paste into ${info.configPath}',
        code: buzzGlobalConfigSnippet(base, key, model),
      ),
    ],
  };
}

/// A minimal OpenAI-SDK example for "any app of your own".
String pythonSnippet(String base, String key, String model) =>
    'from openai import OpenAI\n'
    '\n'
    'client = OpenAI(base_url="$base", api_key="$key")\n'
    'client.chat.completions.create(\n'
    '    model="$model",                # routed to a matching engine automatically\n'
    '    messages=[{"role": "user", "content": "hello"}],\n'
    ')';

/// "images", "videos", or "images and videos" — the human noun for what a media
/// grid makes, from the capabilities it serves. Shared by the media prompt/curl
/// so their wording stays in step.
String mediaNoun({required bool image, required bool video}) => image && video
    ? 'images and videos'
    : video
    ? 'videos'
    : 'images';

/// A paste-ready instruction that has an *agent* client (Hermes / OpenClaw) build
/// a reusable skill around a grid's media API. A media grid can't be wired as a
/// chat "custom endpoint" — it's an HTTP API you call — so instead of a config
/// block we hand the agent the exact contract and let it write the skill. Only
/// the calls the grid actually serves ([image] / [video]) are included; no model
/// name is sent (the relay routes media by `capability`).
String mediaSkillPrompt(
  String base,
  String key, {
  required bool image,
  required bool video,
}) {
  final out = StringBuffer()
    ..writeln(
      'Build a reusable skill I can run whenever I ask you to make '
      '${mediaNoun(image: image, video: video)} with my Grid. The skill just '
      'calls an HTTP API — you never create the media yourself.',
    )
    ..writeln()
    ..writeln('Base URL: $base')
    ..writeln('API key: $key')
    ..writeln()
    ..writeln('Every call is a POST with these headers:')
    ..writeln('  Authorization: Bearer $key')
    ..writeln('  Content-Type: application/json')
    ..writeln('  Accept: text/event-stream')
    ..writeln(
      "Don't send a model name — the grid picks it from \"capability\".",
    )
    ..writeln();
  if (image) {
    out
      ..writeln(
        'Make an image (text → image) — POST $base/media/image/generate',
      )
      ..writeln(
        '  {"capability":"comfyui:image_generation","prompt":"<what to '
        'draw>","width":1024,"height":1024,"steps":4}',
      )
      ..writeln();
  }
  if (video) {
    out
      ..writeln('Make a video (image → video) — POST $base/media/video/i2v')
      ..writeln(
        '  {"capability":"comfyui:i2v","prompt":"<how it should move>",'
        '"duration":"5s","aspect_ratio":"2:3","input_image":{"filename":'
        '"in.png","content_base64":"<base64 of my source image>"}}',
      )
      ..writeln(
        '  IMPORTANT: this animates a starting image I give you. You do '
        'NOT need to open, view, or understand the image — just read the '
        "file's raw bytes and base64-encode them into content_base64. Take the "
        "motion from my words; if I don't describe it, use gentle, natural "
        'motion. Never stop with "I can\'t see the image" — the grid looks at '
        'it, not you.',
      )
      ..writeln();
    if (image) {
      out
        ..writeln(
          'To make a video from a text idea (I gave no image): first call '
          'the image/generate endpoint above, then feed that generated image '
          'into the i2v call.',
        )
        ..writeln();
    }
  }
  out
    ..writeln('Read the reply as a Server-Sent Events stream, line by line:')
    ..writeln('  - lines look like `data: <json>`')
    ..writeln(
      '  - {"type":"progress","progress":<0-100>,"status":"..."} — show progress',
    )
    ..writeln(
      '  - {"type":"result","output_files":[{"filename":"...",'
      '"content_base64":"..."}]} — base64-decode each file to get the media',
    )
    ..writeln('  - {"error":"..."} — it failed; show me the message')
    ..writeln('  - `data: [DONE]` — the stream is finished')
    ..writeln()
    ..writeln(
      "Make the HTTPS call with `curl` (via a subprocess), not Python's "
      'urllib — urllib fails on macOS with CERTIFICATE_VERIFY_FAILED. '
      'Generation can take a few minutes, so allow a timeout of at least 5 '
      'minutes.',
    )
    ..writeln(
      'Save results to ~/Downloads with a unique, timestamped filename '
      'so repeat runs never overwrite each other.',
    )
    ..writeln(
      'After saving, show me the result inline — open or display the '
      "file, don't just print its path. If your vision tool can't read the "
      'file, open it in a browser/viewer instead.',
    )
    ..write(
      'Before you tell me it works, run the skill once end-to-end and '
      'confirm a non-empty file was written.',
    );
  return out.toString();
}

/// A copy-run `curl` example hitting a grid's media API — for "any app of your
/// own" when the grid makes images/video instead of chat. Mirrors
/// [mediaSkillPrompt]'s contract in shell form; includes only the [image] /
/// [video] calls the grid serves.
String mediaApiCurl(
  String base,
  String key, {
  required bool image,
  required bool video,
}) {
  String call(String path, String body) =>
      'curl -N $base/$path \\\n'
      '  -H "Authorization: Bearer $key" \\\n'
      '  -H "Content-Type: application/json" \\\n'
      '  -H "Accept: text/event-stream" \\\n'
      "  -d '$body'";
  final blocks = <String>[
    if (image)
      '# Generate an image (streams Server-Sent Events)\n'
          '${call('media/image/generate', '{"capability":"comfyui:image_generation",'
              '"prompt":"a red bicycle","width":1024,"height":1024,"steps":4}')}',
    if (video)
      '# Animate an image into a video\n'
          '${call('media/video/i2v', '{"capability":"comfyui:i2v",'
              '"prompt":"slow zoom","duration":"5s","aspect_ratio":"2:3",'
              '"input_image":{"filename":"in.png","content_base64":"<base64>"}}')}',
  ];
  return '${blocks.join('\n\n')}\n\n'
      '# The final {"type":"result","output_files":[{"filename","content_base64"}]}\n'
      '# event carries the file — decode content_base64 to save it.';
}
