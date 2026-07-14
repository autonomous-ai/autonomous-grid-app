import 'dart:convert';

/// A plugin the assistant can load: a whole tool backend (a browser it can
/// drive, a search provider it can query), either shipped with Hermes or pulled
/// from a Git repo.
///
/// Distinct from a skill, which is just instructions (and maybe a script) telling
/// the agent how to do one job. Plugins give it new powers; skills teach it what
/// to do with them.
class HermesPlugin {
  const HermesPlugin({
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

  /// Shipped with Hermes (as opposed to installed from a Git repo). Bundled ones
  /// can be turned off but not removed.
  final bool bundled;
}

/// Reads `hermes plugins list --json`.
///
/// Lenient: a field Hermes renames must not blank the screen, so an unreadable
/// entry is skipped and the rest still show. Hermes prints the state as a phrase
/// ("enabled" / "not enabled"), so that's what we match on.
List<HermesPlugin> parseHermesPlugins(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) return const [];

  final plugins = <HermesPlugin>[];
  for (final raw in decoded) {
    if (raw is! Map<String, dynamic>) continue;
    final name = raw['name'];
    if (name is! String || name.isEmpty) continue;
    plugins.add(
      HermesPlugin(
        name: name,
        description: _string(raw['description']),
        version: _string(raw['version']),
        enabled: _string(raw['status']).toLowerCase() == 'enabled',
        bundled: _string(raw['source']).toLowerCase() == 'bundled',
      ),
    );
  }
  plugins.sort((a, b) => a.name.compareTo(b.name));
  return plugins;
}

String _string(Object? raw) => raw is String ? raw : '';
