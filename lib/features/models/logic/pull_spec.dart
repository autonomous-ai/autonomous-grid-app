/// A Hugging Face download URL:
/// `https://huggingface.co/<owner>/<repo>/resolve/<ref>/<path-in-repo>`.
/// Group 1 is the repo id, group 2 the path inside it — the two halves of the
/// `<repo>:<file>` spec `grid pull` takes.
final _hfResolveUrl = RegExp(
  r'^https?://huggingface\.co/([^/]+/[^/]+)/resolve/[^/]+/(.+)$',
  caseSensitive: false,
);

/// Every `grid pull` spec needed to download one catalog version — one per file.
///
/// A split GGUF is several files, and the catalog's `pull_spec` names only the
/// first, so pulling that alone leaves a model the engine can't serve. All the
/// parts are in `urls`, so a spec is derived from each of them.
///
/// Falls back to [pullSpec] when a URL isn't a Hugging Face one: there is no
/// spec to build from a shape we don't recognise, and pulling the subset we did
/// recognise would quietly produce a model with a hole in it.
List<String> versionPullSpecs({
  required List<String> urls,
  required String? pullSpec,
}) {
  final specs = <String>[];
  for (final url in urls) {
    final match = _hfResolveUrl.firstMatch(url.trim());
    if (match == null) return _onlySpec(pullSpec);
    specs.add('${match.group(1)}:${match.group(2)}');
  }
  return specs.isEmpty ? _onlySpec(pullSpec) : specs;
}

List<String> _onlySpec(String? pullSpec) {
  final spec = pullSpec?.trim() ?? '';
  return spec.isEmpty ? const [] : [spec];
}

/// The filename `grid pull <spec>` lands on disk, or null when [spec] carries no
/// usable file half.
///
/// The CLI stores every download flat in `~/.grid/models` — its `local_path()`
/// is `models_dir() / Path(file).name` — so the folder a catalog spec names
/// (`…-GGUF:UD-IQ1_M/model-00001-of-00003.gguf`) never reaches the disk.
/// Comparing the on-disk names against the un-stripped path is why a download
/// that worked perfectly used to report "couldn't be found afterwards".
String? pullSpecFileName(String spec) {
  final colon = spec.indexOf(':');
  if (colon < 0) return null;
  final path = spec.substring(colon + 1).trim();
  final slash = path.lastIndexOf('/');
  final name = slash < 0 ? path : path.substring(slash + 1);
  return name.isEmpty ? null : name;
}
