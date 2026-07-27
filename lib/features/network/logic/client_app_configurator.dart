import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toml/toml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/env_file.dart';
import '../../provider_node/logic/api_engine_catalog.dart';
import 'app_guide_snippets.dart';
import 'client_app_detector.dart';

/// Outcome of an "Apply for me" write. [ApplyOk.note] carries a caveat when we
/// did the safe part but left one manual step (e.g. an existing Hermes config we
/// won't rewrite).
sealed class ApplyResult {
  const ApplyResult();
}

/// The config was updated. [message] names the file touched; [note] (if any) is
/// a follow-up the user still needs to do.
class ApplyOk extends ApplyResult {
  const ApplyOk(this.message, {this.note});
  final String message;
  final String? note;
}

/// The write failed; [message] is a user-readable reason. The dialog then falls
/// back to "copy the config and paste it yourself".
class ApplyError extends ApplyResult {
  const ApplyError(this.message);
  final String message;
}

/// Writes a grid's OpenAI-compatible credentials into a local client's config so
/// a non-technical user never has to hand-edit JSON/YAML. Every write **merges**
/// (never blind-overwrites) and backs an existing file up to `<file>.bak` first.
/// All failures are caught and returned as [ApplyError]. The home directory is
/// injectable so the logic is unit-tested against a temp dir.
class ClientAppConfigurator {
  ClientAppConfigurator({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Future<ApplyResult> apply(
    ClientApp app,
    String base,
    String key,
    List<String> models,
  ) {
    // Guarantee a non-empty list so every downstream write has a default.
    final ids = models.isEmpty ? const [kGuideDefaultModel] : models;
    switch (app) {
      case ClientApp.openClaw:
        return _applyOpenClaw(base, key, ids);
      case ClientApp.hermes:
        // Hermes carries one default and discovers the rest from the endpoint.
        return _applyHermes(base, key, ids.first);
      case ClientApp.codex:
        // Codex names a single model in its config; the key goes to its dotenv.
        return _applyCodex(base, key, ids.first);
      case ClientApp.buzz:
        // Buzz sets one default provider/model for every agent in its global
        // config; the key lives in that file's `env_vars`.
        return _applyBuzz(base, key, ids.first);
    }
  }

  Future<ApplyResult> _applyOpenClaw(
    String base,
    String key,
    List<String> models,
  ) async {
    final file = File('$_home/.openclaw/openclaw.json');
    try {
      final root = await _readJsonObject(file);

      // Add our provider without disturbing the user's other providers.
      // `mode: merge` keeps OpenClaw's built-in providers instead of replacing
      // them (per the OpenClaw model-providers docs). List every grid model so
      // the user can pick any of them, not just the default.
      final modelsNode = _childMap(root, 'models');
      modelsNode['mode'] = 'merge';
      final providers = _childMap(modelsNode, 'providers');
      providers['grid'] = {
        'baseUrl': base,
        'apiKey': key,
        'api': 'openai-completions',
        'models': [
          for (final m in models) {'id': m, 'name': '$m (via Grid)'},
        ],
      };

      // Give a fresh install a working default, but never override a model the
      // user already chose.
      final modelCfg = _childMap(
        _childMap(_childMap(root, 'agents'), 'defaults'),
        'model',
      );
      final setDefault = modelCfg['primary'] == null;
      if (setDefault) modelCfg['primary'] = 'grid/${models.first}';

      await _backupThenWrite(
        file,
        const JsonEncoder.withIndent('  ').convert(root),
      );
      return ApplyOk(
        'Added Grid to ${_display(file)}.',
        note: setDefault
            ? null
            : 'Set your model to grid/${models.first} in OpenClaw to use it.',
      );
    } on Object catch (e) {
      return ApplyError('Couldn\'t update ${_display(file)}: ${_reason(e)}');
    }
  }

  Future<ApplyResult> _applyHermes(
    String base,
    String key,
    String model,
  ) async {
    final config = File('$_home/.hermes/config.yaml');
    final env = File('$_home/.hermes/.env');
    try {
      final text = (await config.exists()) ? await config.readAsString() : '';

      // No config yet → start from the snippet. Otherwise surgically repoint the
      // existing `model:` block at the grid, preserving every other setting and
      // comment (yaml_edit edits in place). Either way, a final pass makes sure
      // the agent's toolsets are all on — files, terminal and the browser.
      // A responses-only model (codex) must speak the Responses dialect, which
      // Hermes only honours on a NAMED provider — a bare `provider: custom` is
      // silently downgraded to chat-completions on a non-OpenAI host.
      final responses = isResponsesOnlyModel(model);
      final YamlEditor editor;
      if (text.trim().isEmpty) {
        await config.parent.create(recursive: true);
        editor = YamlEditor(hermesConfigSnippet(base, key, model));
      } else {
        editor = YamlEditor(text);
        final connection = <String, Object>{
          'provider': responses ? kHermesGridProviderKey : 'custom',
          'base_url': base,
          'api_key': key,
          'default': model,
          'max_tokens': kHermesMaxTokens,
        };
        final existingModel = editor.parseAt([
          'model',
        ], orElse: () => wrapAsYamlNode(null));
        if (existingModel.value is Map) {
          connection.forEach((k, v) => editor.update(['model', k], v));
        } else {
          editor.update(['model'], connection);
        }
        _upsertCustomProvider(
          editor,
          base: base,
          key: key,
          model: model,
          responses: responses,
        );
      }
      ensureAgentToolsets(editor);
      await _backupThenWrite(config, editor.toString().trimRight());

      // Also drop the pair into `.env` as a fallback for other tools that read
      // it; current Hermes resolves the grid from config.yaml (its provider
      // resolution no longer consults `OPENAI_BASE_URL`), so the config write
      // above is what actually points the agent at this grid.
      await _upsertEnvVars(env, {
        'OPENAI_BASE_URL': base,
        'OPENAI_API_KEY': key,
      }, 'Hermes');
      return ApplyOk(
        'Pointed Hermes at this grid (${_display(config)} + ${_display(env)}).',
        note:
            'If Hermes is already open, refresh its model list (or restart '
            'it) to see this grid\'s models.',
      );
    } on Object catch (e) {
      return ApplyError('Couldn\'t update Hermes config: ${_reason(e)}');
    }
  }

  /// Points Codex at the grid: the provider + selected model in
  /// `~/.codex/config.toml`, and the key in `~/.codex/.env` (Codex has no
  /// `api_key` config field — its provider names an env var, and it loads that
  /// dotenv itself, so the user never exports anything in their shell).
  ///
  /// Unlike the YAML/JSON writes, this one re-encodes the whole TOML document:
  /// there's no in-place TOML editor, so an existing file keeps every **setting**
  /// but loses its comments and key order. The `.bak` backup is the safety net.
  Future<ApplyResult> _applyCodex(String base, String key, String model) async {
    final config = File('$_home/.codex/config.toml');
    final env = File('$_home/.codex/.env');
    try {
      final text = (await config.exists()) ? await config.readAsString() : '';
      final root = text.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(TomlDocument.parse(text).toMap());

      // Repoint Codex at the grid (that's what the user asked for), keeping
      // every other provider and setting in the file.
      root['model'] = model;
      root['model_provider'] = kCodexProviderId;
      _childMap(root, 'model_providers')[kCodexProviderId] = {
        'name': 'Grid',
        'base_url': base,
        'env_key': gridApiKeyEnv,
        'wire_api': 'responses',
        // The grid relay streams HTTP SSE, never WebSocket — pin it so Codex
        // doesn't reach for a socket transport the relay doesn't offer.
        'supports_websockets': false,
      };

      await _backupThenWrite(
        config,
        TomlDocument.fromMap(root).toString().trimRight(),
      );
      await _upsertEnvVars(env, {gridApiKeyEnv: key}, 'Codex');
      return ApplyOk(
        'Pointed Codex at this grid (${_display(config)} + ${_display(env)}).',
        note: 'Codex picks it up on its next run — restart any open session.',
      );
    } on Object catch (e) {
      return ApplyError('Couldn\'t update Codex config: ${_reason(e)}');
    }
  }

  /// Points Buzz at the grid by making it the default model for every agent:
  /// writes `provider` / `model` and the `OPENAI_COMPAT_*` pair into Buzz's
  /// global agent config ([kBuzzConfigRelPath]). Merges — a `provider`/`model`
  /// and any other `env_vars` the user set survive, only the grid keys are
  /// (re)written — and backs the old file up.
  ///
  /// Targets the *global* config, not `managed-agents.json`: it leaves the
  /// builtin agents alone and isn't the file the running desktop rewrites on
  /// agent-lifecycle events. Buzz still has to reload it — hence the note.
  Future<ApplyResult> _applyBuzz(String base, String key, String model) async {
    final file = File('$_home/$kBuzzConfigRelPath');
    try {
      final root = await _readJsonObject(file);
      root['provider'] = kBuzzProvider;
      root['model'] = model;
      final env = _childMap(root, 'env_vars');
      env[kBuzzBaseUrlEnv] = base;
      env[kBuzzApiKeyEnv] = key;
      env[kBuzzApiModeEnv] = buzzApiMode(model);

      await _backupThenWrite(
        file,
        const JsonEncoder.withIndent('  ').convert(root),
      );
      return ApplyOk(
        'Pointed Buzz at this grid (${_display(file)}).',
        note: 'Quit and reopen Buzz (or restart its agents) so it picks up '
            'the change.',
      );
    } on Object catch (e) {
      return ApplyError('Couldn\'t update Buzz config: ${_reason(e)}');
    }
  }

  /// Point [appName]'s dotenv at the grid, merging into whatever is already
  /// there — see [EnvFile].
  Future<void> _upsertEnvVars(
    File env,
    Map<String, String> vars,
    String appName,
  ) => EnvFile(env).upsert(vars, addedBy: 'points $appName at this grid');

  /// Registers this grid as a Hermes named provider under `custom_providers`,
  /// upserting by provider **name** (the grid host, e.g. `grid.autonomous.ai`) so
  /// a config file only ever holds one Grid entry: re-applying — or repointing at
  /// a new relay under the same grid — overwrites it in place instead of stacking
  /// a duplicate. Base_url is a secondary match so a manually-renamed entry still
  /// gets reused. Other providers the user set stay intact; the list is created
  /// when it's absent.
  void _upsertCustomProvider(
    YamlEditor editor, {
    required String base,
    required String key,
    required String model,
    required bool responses,
  }) {
    final name = hermesProviderName(base);
    // A responses-only grid also carries a stable `provider_key` (so the
    // `model.provider` selector matches this entry regardless of host) and the
    // `api_mode` that switches Hermes to the Responses dialect.
    final entry = <String, String>{
      'name': name,
      if (responses) 'provider_key': kHermesGridProviderKey,
      'base_url': base,
      'api_key': key,
      'model': model,
      if (responses) 'api_mode': kHermesResponsesApiMode,
    };
    final existing = editor.parseAt([
      'custom_providers',
    ], orElse: () => wrapAsYamlNode(null)).value;
    if (existing is! List) {
      editor.update(['custom_providers'], [entry]);
      return;
    }
    final normBase = base.replaceFirst(RegExp(r'/+$'), '');
    for (var i = 0; i < existing.length; i++) {
      final e = existing[i];
      if (e is! Map) continue;
      final eBase = '${e['base_url'] ?? ''}'.replaceFirst(RegExp(r'/+$'), '');
      // Same Grid entry — matched by name, or by the relay it points at → replace
      // in place so there's only ever one Grid config in the file.
      if ('${e['name'] ?? ''}' == name || eBase == normBase) {
        // Key by key rather than `update([..., i], entry)`: replacing a whole
        // map inside a 4-space-indented list trips a yaml_edit bug (it emits
        // mis-indented YAML, then asserts it can't re-parse its own output).
        // Hermes writes this file with 4-space indent, so that path always
        // blows up when re-pointing an existing Grid entry. Leaf writes are
        // indent-safe; drop the keys this entry no longer carries first, so a
        // stale `api_mode`/`provider_key` can't survive the swap.
        for (final k in e.keys) {
          if (!entry.containsKey('$k')) {
            editor.remove(['custom_providers', i, '$k']);
          }
        }
        entry.forEach((k, v) => editor.update(['custom_providers', i, k], v));
        return;
      }
    }
    editor.appendToList(['custom_providers'], entry);
  }

  Future<Map<String, dynamic>> _readJsonObject(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    final text = (await file.readAsString()).trim();
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('the file isn\'t a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// Returns [parent]'s child object at [key], creating (and re-attaching) an
  /// empty one when it's missing or not an object — so nested writes are safe.
  Map<String, dynamic> _childMap(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    final map = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    parent[key] = map;
    return map;
  }

  Future<void> _backupThenWrite(File file, String contents) async {
    await file.parent.create(recursive: true);
    if (await file.exists()) await file.copy('${file.path}.bak');
    await file.writeAsString('$contents\n');
  }

  String _display(File file) => file.path.startsWith(_home)
      ? '~${file.path.substring(_home.length)}'
      : file.path;

  String _reason(Object e) => e is FormatException ? e.message : '$e';
}

/// The Hermes toolsets the agent needs to do the job this app hands it.
///
/// `toolsets:` is an **allowlist**, not an addition: Hermes with no such key
/// enables everything, and the moment the key exists only the toolsets named in
/// it survive. So the list has to carry every group the app's own UI implies —
/// `file` (`read_file`/`write_file`/`patch`/`search_files`) and `terminal`
/// (`terminal`/`process`/`execute_code`) as much as the web ones. Naming only
/// the web toolsets left an agent that could browse and nothing else, while the
/// chat still offered "Ask before acting" over commands it no longer had; it
/// answered by narrating its own blocks and guessing at a "security scan".
///
/// What the agent may actually *do* with these is the approval gate's call, in
/// front of the user, per action ([decideHermesPermission]) — not something to
/// decide once, silently, by withholding the tool.
const List<String> kHermesToolsets = [
  'hermes-cli',
  'file',
  'terminal',
  'web',
  'browser',
];

/// Ensure Hermes's `toolsets:` enables everything in [kHermesToolsets] — the
/// file and terminal groups the agent works with, plus `browser`, which drives a
/// real headless Chromium (`browser_navigate`); without it the agent has only
/// HTTP fetch, which sites like VNExpress block outright (406, bot detection).
///
/// Applied on every Hermes config write so a non-technical user never has to
/// enable one by hand — and so a config an older build narrowed to three
/// toolsets repairs itself on the next write instead of staying crippled.
/// Idempotent and non-destructive: it appends what's missing and leaves any
/// other toolset the user added alone.
void ensureAgentToolsets(YamlEditor editor) {
  final toolsets = editor.parseAt([
    'toolsets',
  ], orElse: () => wrapAsYamlNode(null)).value;
  if (toolsets is! List) {
    editor.update(['toolsets'], kHermesToolsets);
    return;
  }
  for (final toolset in kHermesToolsets) {
    if (!toolsets.contains(toolset)) editor.appendToList(['toolsets'], toolset);
  }
}

/// The app-config writer, so widgets get it via `ref.read`.
final clientAppConfiguratorProvider = Provider<ClientAppConfigurator>(
  (ref) => ClientAppConfigurator(),
);
