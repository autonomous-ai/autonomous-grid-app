import '../../../infrastructure/state/models/local_files.dart';

/// Matches a llama.cpp split-GGUF shard suffix, e.g. `-00001-of-00005.gguf`.
/// Group 1 is this shard's index, group 2 the total number of shards. Anchored to
/// the end so it only ever strips the trailing marker, never a lookalike earlier
/// in the name.
final _splitShard = RegExp(r'-(\d+)-of-(\d+)\.gguf$', caseSensitive: false);

/// True when [fileName] is one part of a multi-file (split) GGUF — the kind that
/// must be downloaded in full and served by pointing the engine at the first
/// part (llama.cpp then loads its siblings from the same folder).
bool isSplitShard(String fileName) => _splitShard.hasMatch(fileName);

/// This shard's 1-based index within its split set (2 for `…-00002-of-…`), or
/// null when [fileName] isn't a shard. Used to order parts and pick the first.
int? splitShardIndex(String fileName) {
  final match = _splitShard.firstMatch(fileName);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// The total number of parts a shard declares (the `of-N`), or null when
/// [fileName] isn't a shard. Lets the UI say "3 of 5 parts" for an incomplete set.
int? splitShardCount(String fileName) {
  final match = _splitShard.firstMatch(fileName);
  return match == null ? null : int.tryParse(match.group(2)!);
}

/// Strips the trailing `-0000N-of-0000M.gguf` shard marker, yielding the name
/// shared by every part of a split GGUF (e.g. `MiniMax-M3-UD-IQ3_XXS`). Returns
/// [fileName] unchanged when it isn't a shard, so it's safe to call on any name.
String stripSplitSuffix(String fileName) =>
    fileName.replaceFirst(_splitShard, '');

/// A single servable model as the user thinks of it: either one standalone GGUF
/// file, or a set of split shards that together form one model. Grouping keeps
/// the model list and the serve picker honest — a 5-part model reads as one row,
/// not five cryptic `…-00001-of-00005` files.
class ModelGroup {
  ModelGroup({
    required this.displayName,
    required this.files,
    required this.primary,
    required this.isSplit,
    this.expectedParts,
  });

  /// Clean name to show, and to derive the advertise/network name from — the
  /// filename for a standalone model, the shared base for a split set.
  final String displayName;

  /// Every file backing this model, ordered (shards by index). One entry for a
  /// standalone model.
  final List<LocalModel> files;

  /// The file to hand the engine. For a split set this is the first shard
  /// (`…-00001-of-…`); the engine loads its siblings from the same folder.
  final LocalModel primary;

  /// Whether this group is a multi-file split GGUF (vs a standalone file).
  final bool isSplit;

  /// How many parts the shard filenames declare (`-of-N`); null for standalone.
  /// When it exceeds [partCount] the set is missing shards and can't be served.
  final int? expectedParts;

  int get sizeBytes => files.fold(0, (sum, model) => sum + model.sizeBytes);
  double get sizeGb => sizeBytes / 1e9;
  int get partCount => files.length;

  /// A split set is only servable once every declared part is present.
  bool get isComplete =>
      expectedParts == null || partCount >= expectedParts!;

  List<String> get fileNames => [for (final file in files) file.name];
}

/// Collapses a flat list of on-disk GGUF files into servable [ModelGroup]s,
/// merging split shards that share a base name into one group. Preserves the
/// input order by keying each group on its first appearance, so an
/// alphabetically-sorted input stays alphabetically sorted.
List<ModelGroup> groupLocalModels(List<LocalModel> models) {
  final order = <String>[];
  final buckets = <String, List<LocalModel>>{};
  for (final model in models) {
    final key = isSplitShard(model.name) ? stripSplitSuffix(model.name) : model.name;
    final bucket = buckets[key];
    if (bucket == null) {
      buckets[key] = [model];
      order.add(key);
    } else {
      bucket.add(model);
    }
  }

  final groups = <ModelGroup>[];
  for (final key in order) {
    final files = buckets[key]!;
    if (!isSplitShard(files.first.name)) {
      groups.add(ModelGroup(
        displayName: files.first.name,
        files: List.unmodifiable(files),
        primary: files.first,
        isSplit: false,
      ));
      continue;
    }
    final sorted = [...files]
      ..sort((a, b) => (splitShardIndex(a.name) ?? 0)
          .compareTo(splitShardIndex(b.name) ?? 0));
    groups.add(ModelGroup(
      displayName: key,
      files: List.unmodifiable(sorted),
      primary: sorted.first,
      isSplit: true,
      expectedParts: splitShardCount(sorted.first.name),
    ));
  }
  return groups;
}
