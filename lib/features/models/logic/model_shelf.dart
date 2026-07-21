import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import 'model_group.dart';

/// One model as the user thinks of it, wherever it came from.
///
/// The dialog used to render the catalog and the on-disk list as two separate
/// sections, so a downloaded suggested model appeared **twice** — once under
/// "Suggested models" wearing a "Downloaded" tick, and again under "Downloaded
/// models" wearing its size and a delete button. Nothing on screen said the two
/// rows were the same file, and the two halves of what you could do with it
/// (delete it / see what it targets) sat in different places.
///
/// A shelf entry merges the two: [catalog] is set when the model is one the CLI
/// suggests, [group] is set when its files are on disk. At least one is always
/// non-null.
class ShelfModel {
  const ShelfModel({required this.name, this.catalog, this.group});

  /// What to call it — the catalog's filename, or the on-disk display name.
  final String name;

  /// The catalog row, when this is a suggested model. Carries the device target
  /// and memory hint.
  final CatalogEntry? catalog;

  /// The on-disk files, when it's downloaded. Carries size and part count.
  final ModelGroup? group;

  bool get isDownloaded => group != null;
  bool get isSuggested => catalog != null;

  /// Only a downloaded model can be incomplete — a suggestion has no parts yet.
  bool get isComplete => group?.isComplete ?? true;
}

/// Strips the `.gguf` extension for display. The rows already sit under a
/// heading about models, and every name repeating the same five characters is
/// five characters of noise per row.
String prettyModelName(String name) => name.toLowerCase().endsWith('.gguf')
    ? name.substring(0, name.length - 5)
    : name;

/// The key two names are matched on.
///
/// Deliberately the same lenient rule the old `isCatalogModelDownloaded` used
/// before this file replaced it: lowercase, and a suffix match counts. The CLI can save a
/// pull under a slightly different name than the catalog advertises, and a
/// missed match is worse than a loose one — it puts the model back in two
/// places, which is the bug this whole file exists to fix.
String _matchKey(String name) => prettyModelName(name).toLowerCase();

/// True when [a] and [b] name the same model. Suffix-tolerant in both
/// directions, since either side may carry a path or repo prefix.
bool _sameModel(String a, String b) {
  final x = _matchKey(a);
  final y = _matchKey(b);
  return x == y || x.endsWith(y) || y.endsWith(x);
}

/// Merges the curated catalog and the on-disk models into one list, so each
/// model appears exactly once.
///
/// Order is deliberate: suggested models first (downloaded or not) — they're the
/// curated, device-matched ones — then anything else found on disk, which is
/// whatever the user pulled by hand.
List<ShelfModel> buildModelShelf({
  required List<CatalogEntry> catalog,
  required List<ModelGroup> groups,
}) {
  final shelf = <ShelfModel>[];
  // Tracks which on-disk groups a catalog row has already claimed, so a model
  // matching two catalog entries still only leaves the "other" list once.
  final claimed = <ModelGroup>{};

  for (final entry in catalog) {
    ModelGroup? match;
    for (final group in groups) {
      if (claimed.contains(group)) continue;
      if (_sameModel(entry.quantizedFile, group.displayName)) {
        match = group;
        break;
      }
    }
    if (match != null) claimed.add(match);
    shelf.add(
      ShelfModel(
        name: prettyModelName(entry.quantizedFile),
        catalog: entry,
        group: match,
      ),
    );
  }

  for (final group in groups) {
    if (claimed.contains(group)) continue;
    shelf.add(
      ShelfModel(name: prettyModelName(group.displayName), group: group),
    );
  }

  return shelf;
}
