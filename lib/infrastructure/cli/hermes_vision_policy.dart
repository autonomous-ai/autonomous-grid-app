import 'package:yaml_edit/yaml_edit.dart';

import 'hermes_config_file.dart';

/// Which model Hermes hands an image to, and where that model lives.
///
/// Hermes runs side tasks — reading an attached picture, describing a browser
/// screenshot — on a second, "auxiliary" model rather than the one holding the
/// conversation. Left alone it picks its own (Gemini Flash via OpenRouter or
/// Nous), which on a grid means the work leaves the grid: a machine the user
/// pays for sits idle while an image goes to a vendor they never chose.
///
/// Written as `auxiliary.vision` in `~/.hermes/config.yaml`, the shape Hermes
/// documents in `cli-config.yaml.example`:
///
/// ```yaml
/// auxiliary:
///   vision:
///     provider: <the grid's custom_providers name>
///     model: qwen/qwen3.8-27b
/// ```
///
/// [provider] is **not** free text: Hermes resolves it against the built-in
/// names (`auto`, `openrouter`, `nous`…) and, failing those, against the
/// `custom_providers` entries in the same file, matched on that entry's
/// normalised `name` (`custom_provider_aliases`) — which is the branch this
/// depends on. Grid already writes one such entry per grid, so passing the name
/// it writes there is what routes the image back through the grid the chat is
/// already using (`agent/auxiliary_client.py`, the named-custom branch).
class HermesVisionPolicy {
  HermesVisionPolicy({String? home}) : _config = HermesConfigFile(home: home);

  final HermesConfigFile _config;

  static const _model = ['auxiliary', 'vision', 'model'];
  static const _provider = ['auxiliary', 'vision', 'provider'];

  /// The model Hermes is set to read images with, or null when it has never
  /// been told — in which case Hermes picks its own and the screen must not
  /// claim otherwise.
  Future<String?> read() async {
    final value = await _config.valueAt(_model);
    final model = value is String ? value.trim() : '';
    return model.isEmpty ? null : model;
  }

  /// Point image work at [model] on [provider], merged into whatever else the
  /// config holds.
  ///
  /// Writes the whole `auxiliary.vision` map when `auxiliary` is missing:
  /// [HermesConfigFile.upsert] fills one absent level, and a config that has
  /// never mentioned auxiliary models — every fresh install — is two short.
  Future<void> write({required String model, required String provider}) =>
      _config.edit((editor) {
        final auxiliary = editor.parseAt([
          'auxiliary',
        ], orElse: () => wrapAsYamlNode(null)).value;
        if (auxiliary is! Map) {
          editor.update(
            ['auxiliary'],
            {
              'vision': {'provider': provider, 'model': model},
            },
          );
          return;
        }
        HermesConfigFile.upsert(editor, _provider, provider);
        HermesConfigFile.upsert(editor, _model, model);
      });

  /// Hand the choice back to Hermes.
  ///
  /// Both keys go, not just the model: a provider left pointing at a grid with
  /// no model beside it is a half-setting, and Hermes would resolve it to
  /// whatever the main model happens to be rather than to its own default.
  Future<void> clear() => _config.edit((editor) {
    HermesConfigFile.remove(editor, _model);
    HermesConfigFile.remove(editor, _provider);
  });
}
