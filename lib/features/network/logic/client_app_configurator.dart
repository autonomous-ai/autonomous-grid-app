import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Future<ApplyResult> apply(ClientApp app, String base, String key) {
    switch (app) {
      case ClientApp.openClaw:
        return _applyOpenClaw(base, key);
      case ClientApp.hermes:
        return _applyHermes(base, key);
    }
  }

  Future<ApplyResult> _applyOpenClaw(String base, String key) async {
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
          {'id': kGuideDefaultModel, 'name': 'Qwen3 Coder (via Grid)'},
        ],
      };

      // Give a fresh install a working default, but never override a model the
      // user already chose.
      final model =
          _childMap(_childMap(_childMap(root, 'agents'), 'defaults'), 'model');
      final setDefault = model['primary'] == null;
      if (setDefault) model['primary'] = 'grid/$kGuideDefaultModel';

      await _backupThenWrite(
          file, const JsonEncoder.withIndent('  ').convert(root));
      return ApplyOk(
        'Added Grid to ${_display(file)}.',
        note: setDefault
            ? null
            : 'Set your model to grid/$kGuideDefaultModel in OpenClaw to use it.',
      );
    } on Object catch (e) {
      return ApplyError('Couldn\'t update ${_display(file)}: ${_reason(e)}');
    }
  }

  Future<ApplyResult> _applyHermes(String base, String key) async {
    final env = File('$_home/.hermes/.env');
    final config = File('$_home/.hermes/config.yaml');
    try {
      await _upsertEnv(env, {'OPENAI_BASE_URL': base, 'OPENAI_API_KEY': key});

      // A YAML config we can't safely merge is left to the user — we only create
      // one when Hermes has none yet.
      if (await config.exists()) {
        return ApplyOk(
          'Saved your key to ${_display(env)}.',
          note: 'Set base_url to $base in ${_display(config)} (Copy above).',
        );
      }
      await config.parent.create(recursive: true);
      await config.writeAsString('${hermesConfigSnippet(base)}\n');
      return ApplyOk('Configured Hermes in ${_display(config)}.');
    } on Object catch (e) {
      return ApplyError('Couldn\'t update Hermes config: ${_reason(e)}');
    }
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

  /// Sets each `NAME=value` in [vars], replacing an existing line for the same
  /// name and appending the rest — so we never duplicate keys.
  Future<void> _upsertEnv(File file, Map<String, String> vars) async {
    final lines =
        (await file.exists()) ? (await file.readAsString()).split('\n') : <String>[];
    final remaining = Map<String, String>.from(vars);
    final out = <String>[];
    for (final line in lines) {
      final eq = line.indexOf('=');
      final name = eq > 0 ? line.substring(0, eq).trim() : '';
      if (name.isNotEmpty && remaining.containsKey(name)) {
        out.add('$name=${remaining.remove(name)}');
        continue;
      }
      out.add(line);
    }
    while (out.isNotEmpty && out.last.trim().isEmpty) {
      out.removeLast();
    }
    remaining.forEach((name, value) => out.add('$name=$value'));
    await file.parent.create(recursive: true);
    await file.writeAsString('${out.join('\n')}\n');
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
