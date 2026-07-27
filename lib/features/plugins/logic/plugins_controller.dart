import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_plugin_service.dart';
import '../../agent/hermes/hermes_tool.dart';
import 'hermes_plugin.dart';

/// Which section of the screen is open: the plugins (tool backends), the skills
/// (instructions the agent follows), or the MCP servers (external tool sources).
enum PluginsTab {
  plugins('Plugins'),
  skills('Skills'),
  mcp('MCP');

  const PluginsTab(this.label);

  final String label;
}

final pluginsTabProvider = NotifierProvider<PluginsTabNotifier, PluginsTab>(
  PluginsTabNotifier.new,
);

class PluginsTabNotifier extends Notifier<PluginsTab> {
  @override
  PluginsTab build() => PluginsTab.plugins;

  void select(PluginsTab tab) => state = tab;
}

/// The plugin manager seam, or null when the agent isn't installed.
final hermesPluginServiceProvider = Provider<HermesPluginService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesPluginServiceImpl(path);
});

/// The plugins Hermes knows about, read straight from it — the app keeps no
/// second list, so the screen and the agent can't disagree.
///
/// Every action writes through the CLI and re-reads, so a switch that flips has
/// really flipped.
final pluginsProvider =
    AsyncNotifierProvider<PluginsController, List<HermesPlugin>>(
      PluginsController.new,
    );

class PluginsController extends AsyncNotifier<List<HermesPlugin>> {
  @override
  Future<List<HermesPlugin>> build() => _load();

  Future<List<HermesPlugin>> _load() async {
    final service = ref.read(hermesPluginServiceProvider);
    if (service == null) return const [];
    final raw = await service.listJson();
    if (raw.trim().isEmpty) return const [];
    return parseHermesPlugins(raw);
  }

  /// Add a plugin from a Git URL or `owner/repo`. Returns null on success, else
  /// a line to show the user.
  Future<String?> install(String identifier) =>
      _act((service) => service.install(identifier.trim()));

  Future<String?> setEnabled(String name, {required bool enabled}) =>
      _act((service) => enabled ? service.enable(name) : service.disable(name));

  Future<String?> remove(String name) => _act((s) => s.remove(name));

  /// Run one write against Hermes and re-read its list. Failures come back as a
  /// message rather than an exception: every caller is a button, and a button
  /// needs something to say.
  Future<String?> _act(Future<void> Function(HermesPluginService) write) async {
    final service = ref.read(hermesPluginServiceProvider);
    if (service == null) return _noAgent;
    try {
      await write(service);
    } on HermesPluginException catch (error) {
      return error.message;
    }
    state = AsyncData(await _load());
    return null;
  }

  static const _noAgent =
      "This computer isn't set up to run the assistant yet. Open the account "
      'menu ▸ This computer to finish setting it up.';
}
