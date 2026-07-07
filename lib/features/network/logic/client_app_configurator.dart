import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../../core/grid_paths.dart';
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
      ClientApp app, String base, String key, String model) {
    switch (app) {
      case ClientApp.openClaw:
        return _applyOpenClaw(base, key, model);
      case ClientApp.hermes:
        return _applyHermes(base, key, model);
    }
  }

  Future<ApplyResult> _applyOpenClaw(
      String base, String key, String model) async {
    final file = File('$_home/.openclaw/openclaw.json');
    try {
      final root = await _readJsonObject(file);

      // Add our provider without disturbing the user's other providers.
      // `mode: merge` keeps OpenClaw's built-in providers instead of replacing
      // them (per the OpenClaw model-providers docs).
      final models = _childMap(root, 'models');
      models['mode'] = 'merge';
      final providers = _childMap(models, 'providers');
      providers['grid'] = {
        'baseUrl': base,
        'apiKey': key,
        'api': 'openai-completions',
        'models': [
          {'id': model, 'name': '$model (via Grid)'},
        ],
      };

      // Give a fresh install a working default, but never override a model the
      // user already chose.
      final modelCfg =
          _childMap(_childMap(_childMap(root, 'agents'), 'defaults'), 'model');
      final setDefault = modelCfg['primary'] == null;
      if (setDefault) modelCfg['primary'] = 'grid/$model';

      await _backupThenWrite(
          file, const JsonEncoder.withIndent('  ').convert(root));
      return ApplyOk(
        'Added Grid to ${_display(file)}.',
        note: setDefault
            ? null
            : 'Set your model to grid/$model in OpenClaw to use it.',
      );
    } on Object catch (e) {
      return ApplyError('Couldn\'t update ${_display(file)}: ${_reason(e)}');
    }
  }

  Future<ApplyResult> _applyHermes(
      String base, String key, String model) async {
    final config = File('$_home/.hermes/config.yaml');
    final env = File('$_home/.hermes/.env');
    try {
      final text = (await config.exists()) ? await config.readAsString() : '';

      // No config yet → write a fresh one straight from the snippet. Otherwise
      // surgically repoint the existing `model:` block at the grid, preserving
      // every other setting and comment (yaml_edit edits in place).
      if (text.trim().isEmpty) {
        await config.parent.create(recursive: true);
        await _backupThenWrite(config, hermesConfigSnippet(base, key, model));
      } else {
        final editor = YamlEditor(text);
        final connection = <String, Object>{
          'provider': 'custom',
          'base_url': base,
          'api_key': key,
          'default': model,
          'max_tokens': kHermesMaxTokens,
        };
        final existingModel =
            editor.parseAt(['model'], orElse: () => wrapAsYamlNode(null));
        if (existingModel.value is Map) {
          connection.forEach((k, v) => editor.update(['model', k], v));
        } else {
          editor.update(['model'], connection);
        }
        _upsertCustomProvider(editor, base: base, key: key, model: model);
        await _backupThenWrite(config, editor.toString().trimRight());
      }

      // Also drop the pair into `.env`: Hermes reads OPENAI_BASE_URL +
      // OPENAI_API_KEY as a direct custom endpoint (docs: "when base_url is set,
      // Hermes ignores the provider and calls that endpoint directly"), and its
      // convention is that secrets live in `.env`. config.yaml (higher
      // precedence) still carries the model, so the grid resolves either way.
      await _upsertEnvVars(env, {
        'OPENAI_BASE_URL': base,
        'OPENAI_API_KEY': key,
      });
      return ApplyOk(
          'Pointed Hermes at this grid (${_display(config)} + ${_display(env)}).');
    } on Object catch (e) {
      return ApplyError('Couldn\'t update Hermes config: ${_reason(e)}');
    }
  }

  /// Upserts `KEY=value` lines in a dotenv file, replacing an existing
  /// uncommented assignment in place (commented `# KEY=` template lines are left
  /// alone) and appending any that are new under a Grid header. Preserves every
  /// other line/comment and backs an existing file up to `<file>.bak` first.
  Future<void> _upsertEnvVars(File env, Map<String, String> vars) async {
    final lines = (await env.exists()) ? await env.readAsLines() : <String>[];
    final remaining = Map<String, String>.from(vars);
    final out = <String>[];
    for (final line in lines) {
      final key = remaining.keys.firstWhere(
        (k) => RegExp('^\\s*${RegExp.escape(k)}\\s*=').hasMatch(line),
        orElse: () => '',
      );
      if (key.isEmpty) {
        out.add(line);
        continue;
      }
      out.add('$key=${remaining.remove(key)}');
    }
    if (remaining.isNotEmpty) {
      if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
      out.add('# Added by Grid — points Hermes at this grid');
      remaining.forEach((k, v) => out.add('$k=$v'));
    }
    await env.parent.create(recursive: true);
    if (await env.exists()) await env.copy('${env.path}.bak');
    await env.writeAsString('${out.join('\n')}\n');
  }

  /// Registers this grid as a Hermes named provider under `custom_providers`,
  /// upserting by relay base_url so re-applying never duplicates it and any other
  /// providers the user set stay intact. Creates the list when it's absent.
  void _upsertCustomProvider(YamlEditor editor,
      {required String base, required String key, required String model}) {
    final entry = <String, String>{
      'name': hermesProviderName(base),
      'base_url': base,
      'api_key': key,
      'model': model,
    };
    final existing =
        editor.parseAt(['custom_providers'], orElse: () => wrapAsYamlNode(null))
            .value;
    if (existing is! List) {
      editor.update(['custom_providers'], [entry]);
      return;
    }
    final normBase = base.replaceFirst(RegExp(r'/+$'), '');
    for (var i = 0; i < existing.length; i++) {
      final e = existing[i];
      if (e is! Map) continue;
      final eBase = '${e['base_url'] ?? ''}'.replaceFirst(RegExp(r'/+$'), '');
      if (eBase == normBase) {
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
    final map =
        existing is Map ? Map<String, dynamic>.from(existing) : <String, dynamic>{};
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

/// The app-config writer, so widgets get it via `ref.read`.
final clientAppConfiguratorProvider = Provider<ClientAppConfigurator>(
  (ref) => ClientAppConfigurator(),
);
