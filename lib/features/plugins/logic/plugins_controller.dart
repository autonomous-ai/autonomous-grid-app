import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_extensions_registry.dart';
import '../../agents/logic/agent_plugin.dart';

/// The plugins the selected agent knows about, read straight from its plugins
/// plane — the app keeps no second list, so the screen and the agent can't
/// disagree.
///
/// Every action writes through the plane and re-reads, so a switch that flips
/// has really flipped.
final pluginsProvider =
    AsyncNotifierProvider<PluginsController, List<AgentPlugin>>(
      PluginsController.new,
    );

class PluginsController extends AsyncNotifier<List<AgentPlugin>> {
  @override
  Future<List<AgentPlugin>> build() {
    final tool = ref.watch(extensionAgentProvider);
    final plane = ref.watch(agentExtensionsProvider(tool))?.plugins;
    return plane?.list() ?? Future.value(const []);
  }

  AgentPluginsPlane? get _plane {
    final tool = ref.read(extensionAgentProvider);
    return ref.read(agentExtensionsProvider(tool))?.plugins;
  }

  /// Add a plugin from a Git URL or `owner/repo`. Returns null on success, else
  /// a line to show the user.
  Future<String?> install(String identifier) =>
      _act((plane) => plane.install(identifier.trim()));

  Future<String?> setEnabled(String name, {required bool enabled}) =>
      _act((plane) => plane.setEnabled(name, enabled: enabled));

  Future<String?> remove(String name) => _act((plane) => plane.remove(name));

  /// Run one write against the agent and re-read its list. Failures come back
  /// as a message rather than an exception: every caller is a button, and a
  /// button needs something to say.
  Future<String?> _act(Future<void> Function(AgentPluginsPlane) write) async {
    final plane = _plane;
    if (plane == null) return _noAgent;
    try {
      await write(plane);
    } on AgentExtensionException catch (error) {
      return error.message;
    }
    state = AsyncData(await plane.list());
    return null;
  }

  static const _noAgent =
      "This computer isn't set up to run the assistant yet. Open the account "
      'menu ▸ This computer to finish setting it up.';
}
