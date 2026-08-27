import '../../../infrastructure/state/models/local_files.dart';
import '../../../shared/copy/plural.dart';
import 'model_group.dart';

/// A size in the units a person reads. Decimal GB (10^9) to match the sizes the
/// catalog quotes, no decimal above 10 GB — a tenth of a gigabyte is noise at
/// that scale — and MB below one, so a 300 MB leftover doesn't read as
/// "0.3 GB".
String modelSizeLabel(int bytes) {
  if (bytes < 1000000000) return '${(bytes / 1e6).round()} MB';
  final gb = bytes / 1e9;
  return gb >= 10
      ? '${gb.toStringAsFixed(0)} GB'
      : '${gb.toStringAsFixed(1)} GB';
}

/// Whether a stored item is usable or is the wreck of a download that stopped.
enum StoredItemKind {
  /// Every byte is here — this model can be served.
  ready,

  /// A `.gguf.part` the CLI never finished, or a split set missing shards. It
  /// takes up its space without being servable, which is why it gets its own
  /// kind: it's the first thing worth deleting when a disk fills up.
  unfinished,
}

/// One thing occupying space under `~/.grid/models`, as the user thinks of it:
/// a downloaded model, or the remains of a download that stopped partway.
///
/// A split model — and the unfinished shard belonging to it — collapse into a
/// single item, so "delete this" removes every file it left behind rather than
/// freeing one shard and leaving the other twelve gigabytes on disk.
class StoredItem {
  const StoredItem({
    required this.label,
    required this.files,
    required this.sizeBytes,
    required this.kind,
    this.detail,
  });

  /// What to call it on screen: the filename for a standalone model, the name
  /// its shards share for a split one.
  final String label;

  /// Every filename backing it, as `grid rm` wants them (a plain name under
  /// `~/.grid/models`, `.part` suffix included where there is one).
  final List<String> files;

  final int sizeBytes;
  final StoredItemKind kind;

  /// The quiet second line — part counts, or why this one isn't usable.
  final String? detail;

  bool get isUnfinished => kind == StoredItemKind.unfinished;
}

/// Everything on disk, biggest first.
///
/// Size order rather than the alphabet because of the question this list
/// answers: the user is out of space and wants to know what to remove, and the
/// one 15 GB model is worth more than the ten small ones under it.
///
/// [partials] are folded into the model they belong to when their names match
/// (a split set half-downloaded is one model, not two rows), and stand alone
/// otherwise.
List<StoredItem> storedItems({
  required List<ModelGroup> groups,
  required List<DownloadingModel> partials,
}) {
  final stuckByName = <String, List<DownloadingModel>>{};
  for (final partial in partials) {
    stuckByName
        .putIfAbsent(_groupKey(partial.name), () => <DownloadingModel>[])
        .add(partial);
  }

  final items = <StoredItem>[];
  for (final group in groups) {
    final stuck = stuckByName.remove(group.displayName) ?? const [];
    final unfinished = stuck.isNotEmpty || !group.isComplete;
    items.add(
      StoredItem(
        label: group.displayName,
        files: [
          ...group.fileNames,
          for (final partial in stuck) partial.fileName,
        ],
        sizeBytes:
            group.sizeBytes +
            stuck.fold(0, (sum, partial) => sum + partial.bytesSoFar),
        kind: unfinished ? StoredItemKind.unfinished : StoredItemKind.ready,
        detail: _detailLine(
          partsHere: group.partCount,
          expectedParts:
              group.expectedParts ??
              (stuck.isEmpty ? null : splitShardCount(stuck.first.name)),
          unfinished: unfinished,
        ),
      ),
    );
  }

  // What's left never finished a single part, so no group speaks for it.
  for (final entry in stuckByName.entries) {
    items.add(
      StoredItem(
        label: entry.key,
        files: [for (final partial in entry.value) partial.fileName],
        sizeBytes: entry.value.fold(0, (sum, p) => sum + p.bytesSoFar),
        kind: StoredItemKind.unfinished,
        detail: _detailLine(
          partsHere: 0,
          expectedParts: splitShardCount(entry.value.first.name),
          unfinished: true,
        ),
      ),
    );
  }

  items.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
  return items;
}

int totalStoredBytes(Iterable<StoredItem> items) =>
    items.fold(0, (sum, item) => sum + item.sizeBytes);

/// What's on disk, counted: "2 models · 1 unfinished download". Unfinished ones
/// are counted apart because they are the ones worth deleting first — they hold
/// space without being usable, and a total that folds them in hides that.
String storageCounts(List<StoredItem> items) {
  final unfinished = items.where((item) => item.isUnfinished).length;
  final ready = items.length - unfinished;
  final parts = [
    if (ready > 0) ready == 1 ? '1 model' : '$ready models',
    if (unfinished > 0)
      unfinished == 1
          ? '1 unfinished download'
          : '$unfinished unfinished downloads',
  ];
  return parts.join(' · ');
}

/// The line above the list: how much space is gone, and to what.
String storageSummary(List<StoredItem> items) => items.isEmpty
    ? 'Nothing downloaded yet'
    : '${modelSizeLabel(totalStoredBytes(items))} used · '
          '${storageCounts(items)}';

/// True when [item] is one the running engine is serving, so deleting it would
/// pull the file out from under a live model. Checks every backing file and the
/// name they share — the engine may have been started against either.
bool isStoredItemInUse(StoredItem item, String? servingModel) =>
    isModelInUse(item.label, servingModel) ||
    item.files.any((file) => isModelInUse(file, servingModel));

/// True when [modelName] (a local gguf filename) matches what the running
/// engine is serving. Exact for an in-session built-in serve (we pass the gguf name as
/// `--serve`); a lenient substring match otherwise, so an engine adopted on
/// restart — whose record stores the advertised name, a prefix of the
/// filename — still counts. Biased toward "in use" so we never delete a model that's live.
bool isModelInUse(String modelName, String? servingModel) {
  if (servingModel == null || servingModel.trim().isEmpty) return false;
  final name = modelName.toLowerCase();
  for (final part in servingModel.split(',')) {
    final m = part.trim().toLowerCase();
    if (m.isEmpty) continue;
    if (name == m || name.contains(m) || m.contains(name)) return true;
  }
  return false;
}

/// The key a file groups under — the same one [groupLocalModels] uses, so a
/// half-downloaded shard lands on the model its finished siblings built.
String _groupKey(String fileName) =>
    isSplitShard(fileName) ? stripSplitSuffix(fileName) : fileName;

/// The second line: how many parts are here, and whether that's all of them.
String? _detailLine({
  required int partsHere,
  required int? expectedParts,
  required bool unfinished,
}) {
  if (!unfinished) {
    return expectedParts == null
        ? null
        : '$expectedParts ${plural(expectedParts, 'part')}';
  }
  if (expectedParts == null) return 'Download stopped partway';
  return 'Download stopped partway · $partsHere of $expectedParts '
      '${plural(expectedParts, 'part')} here';
}
