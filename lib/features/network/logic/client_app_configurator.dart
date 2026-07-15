import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:toml/toml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/env_file.dart';
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
      // the `browser` toolset is on so the agent can actually open web pages.
      final YamlEditor editor;
      if (text.trim().isEmpty) {
        await config.parent.create(recursive: true);
        editor = YamlEditor(hermesConfigSnippet(base, key, model));
      } else {
        editor = YamlEditor(text);
        final connection = <String, Object>{
          'provider': 'custom',
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
        _upsertCustomProvider(editor, base: base, key: key, model: model);
      }
      ensureBrowserToolset(editor);
      await _backupThenWrite(config, editor.toString().trimRight());

      // Also drop the pair into `.env`: Hermes reads OPENAI_BASE_URL +
      // OPENAI_API_KEY as a direct custom endpoint (docs: "when base_url is set,
      // Hermes ignores the provider and calls that endpoint directly"), and its
      // convention is that secrets live in `.env`. config.yaml (higher
      // precedence) still carries the model, so the grid resolves either way.
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
  }) {
    final name = hermesProviderName(base);
    final entry = <String, String>{
      'name': name,
      'base_url': base,
      'api_key': key,
      'model': model,
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
        editor.update(['custom_providers', i], entry);
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

/// Ensure Hermes's `toolsets:` enables the `browser` toolset, which drives a
/// real headless Chromium (`browser_navigate`).
///
/// Without it the agent has only HTTP web fetch (`web_search` / `web_extract`),
/// which sites like VNExpress block outright (406, bot detection) — a real
/// browser renders the page and gets through. Applied on every Hermes config
/// write so a non-technical user never has to enable it by hand. Idempotent and
/// non-destructive: it appends `browser` to an existing list, leaving the user's
/// other toolsets intact, and seeds a sensible default when there's none yet.
void ensureBrowserToolset(YamlEditor editor) {
  const browser = 'browser';
  final toolsets = editor.parseAt([
    'toolsets',
  ], orElse: () => wrapAsYamlNode(null)).value;
  if (toolsets is! List) {
    editor.update(['toolsets'], const ['hermes-cli', 'web', browser]);
    return;
  }
  if (toolsets.contains(browser)) return;
  editor.appendToList(['toolsets'], browser);
}

/// The app-config writer, so widgets get it via `ref.read`.
final clientAppConfiguratorProvider = Provider<ClientAppConfigurator>(
  (ref) => ClientAppConfigurator(),
);
