/// A plugin the assistant can load: a whole tool backend (a browser it can
/// drive, a search provider it can query), either shipped with the agent or
/// pulled from a Git repo.
///
/// Distinct from a skill, which is just instructions (and maybe a script)
/// telling the agent how to do one job. Plugins give it new powers; skills teach
/// it what to do with them.
///
/// Cross-agent vocabulary; today only Hermes has a plugin manager, and its JSON
/// is parsed next to its adapter.
class AgentPlugin {
  const AgentPlugin({
    required this.name,
    required this.description,
    required this.version,
    required this.enabled,
    required this.bundled,
  });

  final String name;
  final String description;
  final String version;

  /// Whether the agent loads it. A bundled plugin sits there disabled until the
  /// user turns it on.
  final bool enabled;

  /// Shipped with the agent (as opposed to installed from a Git repo). Bundled
  /// ones can be turned off but not removed.
  final bool bundled;
}
