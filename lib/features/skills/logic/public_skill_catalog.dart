import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_skill.dart';
import 'skill_author.dart';
import 'skill_files.dart';
import 'skill_import.dart';

/// Where the bundled catalog sits in the asset bundle.
///
/// One folder per publisher directly under it — `public_skill/anthropic/…` —
/// and that folder's name *is* the author. Adding someone else's skills is
/// therefore a folder, not a code change, and nothing has to parse a name out
/// of a manifest that may not be there. Everything below the publisher is
/// theirs to lay out however they already do.
const String kPublicSkillRoot = 'assets/public_skill';

/// One skill from the catalog the app ships with.
///
/// Bundled rather than fetched: the Skills screen makes no network calls, and a
/// catalog that needed one would be empty exactly when a new user opens it.
class PublicSkill {
  const PublicSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.collection,
    required this.author,
    required this.assetKeys,
  });

  /// Path under [kPublicSkillRoot], e.g.
  /// `claude_plugin/bio-research/skills/start`. Unique, and stable across
  /// releases, so it's what the UI keys rows by.
  final String id;

  /// From the card's front matter — the name the agent will know it by.
  final String name;

  final String description;

  /// The plugin it was published in (`bio-research`, `common-room`), or empty
  /// for a skill that ships on its own. Shown beside the author, because two
  /// skills called `start` are only told apart by where they came from.
  final String collection;

  /// Who published it — the publisher folder this skill sits under.
  final String author;

  /// Every file in the skill's folder, as asset keys.
  final List<String> assetKeys;

  /// The folder name it would take in the store — which is also how the screen
  /// knows whether it's already installed.
  String get slug => skillSlug(name);

  /// True when [installed] holds a skill this one would collide with.
  ///
  /// By slug rather than by id: a catalog skill copied into the store keeps its
  /// card's name, and that name is what the agent resolves. Two folders with
  /// one name is the collision that matters, wherever each came from.
  bool isInstalled(Iterable<AgentSkill> installed) =>
      installed.any((skill) => skill.path.split('/').last == slug);
}

/// Read the bundled catalog: every `SKILL.md` under [kPublicSkillRoot], with the
/// files that belong to it.
///
/// Driven by the asset manifest rather than a checked-in index, so adding a
/// skill to the folder (and re-running `scripts/sync_public_skill_assets.sh`)
/// is all it takes — there is no second list to forget to update.
Future<List<PublicSkill>> loadPublicSkills(AssetBundle bundle) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final keys = manifest
      .listAssets()
      .where((key) => key.startsWith('$kPublicSkillRoot/'))
      .toList();

  final plugins = await _readPlugins(bundle, keys);

  // Group every asset under the folder that owns it, so a skill arrives with
  // its scripts and references rather than as a lone card.
  final cards = keys.where((key) => key.endsWith('/$kSkillCardFileName'));
  final skills = <PublicSkill>[];

  for (final card in cards) {
    final dir = card.substring(0, card.length - kSkillCardFileName.length - 1);
    final fields = readSkillCardFields(await bundle.loadString(card));
    final plugin = _pluginOwning(dir, plugins);
    final id = dir.substring(kPublicSkillRoot.length + 1);
    skills.add(
      PublicSkill(
        id: id,
        // A card with no name still lists, under its folder name — hiding a
        // skill the user can see in the folder would be the worse lie.
        name: fields.name.isEmpty ? dir.split('/').last : fields.name,
        description: fields.description,
        collection: plugin?.name ?? '',
        author: _publisherOf(id),
        assetKeys: keys.where((key) => key.startsWith('$dir/')).toList(),
      ),
    );
  }

  skills.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return skills;
}

/// The publisher folder a skill sits under, shown verbatim — rename the folder
/// and the cards follow. Empty only for a skill dropped loose at the catalog's
/// root, which has no publisher to name.
String _publisherOf(String id) {
  final cut = id.indexOf('/');
  return cut == -1 ? '' : id.substring(0, cut);
}

/// What a plugin says about itself — its name, which is what a card shows
/// beside the publisher.
class _Plugin {
  const _Plugin({required this.root, required this.name});

  /// The plugin's own folder, as an asset key prefix.
  final String root;

  final String name;
}

/// Every plugin in the catalog, found by its manifest rather than by where the
/// folders sit.
///
/// A publisher's own layout is not something the app gets to assume:
/// Anthropic's `claude_plugin/partner-built/` holds four plugins of its own, so
/// a fixed path segment names the wrong thing for a quarter of that catalog —
/// `partner-built` instead of `common-room`.
Future<Map<String, _Plugin>> _readPlugins(
  AssetBundle bundle,
  List<String> keys,
) async {
  const suffix = '.claude-plugin/plugin.json';
  final plugins = <String, _Plugin>{};
  for (final key in keys.where((key) => key.endsWith('/$suffix'))) {
    final root = key.substring(0, key.length - suffix.length - 1);
    var name = root.split('/').last;
    try {
      final decoded = jsonDecode(await bundle.loadString(key));
      final declared = decoded is Map ? decoded['name'] : null;
      if (declared is String && declared.isNotEmpty) name = declared;
    } on Object {
      // A manifest we can't read still leaves the folder name, which is the
      // part the user recognises anyway.
    }
    plugins[root] = _Plugin(root: root, name: name);
  }
  return plugins;
}

/// The plugin a skill belongs to: the deepest one whose folder contains it.
///
/// Deepest, not first — `partner-built/common-room/skills/x` sits inside both
/// `partner-built` (were it ever to gain a manifest) and `common-room`, and the
/// nearer one is the one that published it.
_Plugin? _pluginOwning(String skillDir, Map<String, _Plugin> plugins) {
  _Plugin? best;
  for (final plugin in plugins.values) {
    if (!skillDir.startsWith('${plugin.root}/')) continue;
    if (best == null || plugin.root.length > best.root.length) best = plugin;
  }
  return best;
}

/// Lay a catalog skill down in [directory], file for file.
///
/// Bytes rather than strings: `rootBundle.load` is the one reader that works
/// for every file a skill might carry, and a script copied through a decode
/// would come out with different bytes than it went in with.
Future<void> writePublicSkillTo(
  AssetBundle bundle,
  PublicSkill skill,
  Directory directory,
) async {
  final prefix = '$kPublicSkillRoot/${skill.id}/';
  for (final key in skill.assetKeys) {
    final file = File('${directory.path}/${key.substring(prefix.length)}');
    await file.parent.create(recursive: true);
    final data = await bundle.load(key);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
}

/// The catalog. Read once — it's on disk inside the app and cannot change while
/// it runs.
final publicSkillsProvider = FutureProvider<List<PublicSkill>>(
  (ref) => loadPublicSkills(ref.watch(publicSkillBundleProvider)),
);
