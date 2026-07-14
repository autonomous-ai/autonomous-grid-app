/// Copy-ready configuration snippets that point an OpenAI-compatible client at a
/// grid. Pure string builders (no I/O) so they're unit-tested once and reused by
/// both the app-guide dialog and the "Apply for me" configurator. Each takes the
/// grid's real relay BASE_URL / API_KEY — the same pair `grid info --env` prints.
library;

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
/// `model:` selection (`provider: custom` + `base_url`/`api_key`, the `default`
/// model, and a `max_tokens` cap — see [kHermesMaxTokens]) plus a
/// `custom_providers` entry registering the grid as a named provider. Hermes
/// reads it all here — no `.env`.
String hermesConfigSnippet(String base, String key, String model) =>
    'model:\n'
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
