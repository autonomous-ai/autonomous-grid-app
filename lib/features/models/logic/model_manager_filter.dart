import '../../../infrastructure/api/models/model_catalog.dart';
import 'model_shelf.dart';

/// Which half of the model manager is showing.
///
/// The dialog used to stack both on one scroll: everything on disk, then the
/// catalog's suggestions, then a fold-out paste box — three unrelated jobs in one
/// 720px column. They're split because they answer different questions ("what do
/// I have / what should I get") and only one of them is ever the reason the
/// dialog was opened.
enum ModelManagerTab {
  /// What's on this computer: sizes, what's running, and the way to delete.
  installed('Installed'),

  /// What to get next: the catalog's device-ranked picks, plus a paste box for
  /// anything it doesn't list.
  discover('Discover');

  const ModelManagerTab(this.label);

  /// What the segmented control shows.
  final String label;
}

/// A `owner/repo:file.gguf` spec, which is what the Discover search box accepts
/// besides a plain search word.
///
/// Deliberately loose: it only has to tell "the user is pasting a spec" apart
/// from "the user is typing a name", and a spec that turns out to be wrong is
/// reported by the download itself, in the one place that actually knows.
final _pullSpec = RegExp(
  r'^[^\s/:]+/[^\s/:]+:\S+\.gguf$',
  caseSensitive: false,
);

/// True when [text] reads as something to download rather than something to
/// search for — so the Discover box can offer Download instead of filtering a
/// list to nothing.
///
/// Multi-line input counts too: a split GGUF is pasted as one line per part, and
/// every line has to look like a spec (a stray word among them is a typo, not a
/// download).
bool looksLikePullSpec(String text) {
  final lines = [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.isEmpty) return false;
  return lines.every(_pullSpec.hasMatch);
}

/// Filters the installed shelf by the text typed in the Installed search box.
///
/// Matches on the display name only. A model's other facts (its device target,
/// its size) are numbers the user compares, not words they'd search by, and
/// including them makes "32" match every model needing 32 GB.
List<ShelfModel> filterInstalled(List<ShelfModel> installed, String text) {
  final needle = text.trim().toLowerCase();
  if (needle.isEmpty) return installed;
  return [
    for (final model in installed)
      if (model.name.toLowerCase().contains(needle)) model,
  ];
}

/// Filters catalog picks by the text typed in the Discover search box.
///
/// Searches the repo id as well as the filename: the row shows a shortened name
/// (`Qwen3.6-14B-Instruct`), but people search by what they read elsewhere, which
/// is usually the full `owner/repo`.
List<CatalogModelPick> filterPicks(List<CatalogModelPick> picks, String text) {
  final needle = text.trim().toLowerCase();
  if (needle.isEmpty) return picks;
  return [
    for (final pick in picks)
      if ((pick.repoId ?? '').toLowerCase().contains(needle) ||
          (pick.file ?? '').toLowerCase().contains(needle))
        pick,
  ];
}

/// Strips a name down to what survives the trip through a download: lowercase,
/// letters and digits only. `Qwen2.5-3B-Instruct-GGUF` and
/// `qwen2.5-3b-instruct-q4_k_m.gguf` differ in punctuation and quant, but both
/// reduce to a form where one contains the other.
String _installKey(String value) =>
    value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// Whether a catalog model is already under `~/.grid/models`, given the local
/// GGUF filenames from `localModelsProvider`.
///
/// Two ways to match, because the two catalog shapes carry different facts. A
/// device-ranked pick names the exact [file] it would download, so that's an
/// equality test. A plain list entry knows only its `repo_id`, so it falls back
/// to asking whether any local filename reads as coming from that repo — the
/// repo's tail (minus the `-GGUF` suffix every quant repo carries) appearing
/// inside the filename.
///
/// The fallback is deliberately *model*-level, not file-level: having a
/// different quant of the same model still means the answer to "do I have this
/// one?" is yes, and offering it under "Not installed" would send the user to
/// download a second copy. Short tails are refused — a 3-character stem matches
/// half the shelf by accident.
bool isCatalogModelInstalled({
  required String repoId,
  String? file,
  required Iterable<String> localFileNames,
}) {
  final local = [for (final name in localFileNames) name.toLowerCase()];
  if (file != null && file.isNotEmpty && local.contains(file.toLowerCase())) {
    return true;
  }
  final tail = repoId.contains('/') ? repoId.split('/').last : repoId;
  final stem = _installKey(tail.replaceAll(RegExp(r'[-_]?gguf$', caseSensitive: false), ''));
  if (stem.length < 6) return false;
  return local.any((name) => _installKey(name).contains(stem));
}

/// Total bytes of every model on disk — the number the "manage" screen exists to
/// act on, and the one thing the old header never said.
int totalInstalledBytes(List<ShelfModel> installed) =>
    installed.fold(0, (sum, model) => sum + (model.group?.sizeBytes ?? 0));

/// Bytes → the compact label used across the dialog: `5.7 GB`, and `15 GB` once
/// a decimal is noise.
String formatGb(int bytes) {
  final gb = bytes / 1e9;
  if (gb >= 10) return '${gb.toStringAsFixed(0)} GB';
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  return '${(bytes / 1e6).toStringAsFixed(0)} MB';
}
