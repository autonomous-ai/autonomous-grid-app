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
  final stem = _installKey(
    tail.replaceAll(RegExp(r'[-_]?gguf$', caseSensitive: false), ''),
  );
  if (stem.length < 6) return false;
  return local.any((name) => _installKey(name).contains(stem));
}
