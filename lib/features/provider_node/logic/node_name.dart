/// The name this machine advertises as a node when it joins a grid — shown on
/// the grid page — and the stable engine id used for `grid join --name` /
/// `grid leave --engine`. Derived from the machine's own name so two machines
/// don't both appear as a generic "grid-app".
///
/// Kept filesystem-safe because the CLI stores each engine's run record in a
/// file named after this id, and stable across restarts (a given host always
/// derives the same id) so `ProviderRunController.reconcile` and the stop path
/// can still find the engine. [hostname] is injected for tests; production
/// passes `Platform.localHostname`. Falls back to [fallbackNodeName] when the
/// host name is empty or has nothing usable left after sanitising — never an
/// empty `--name`, which the CLI would replace with a random `engine-<hex>` id.
String deriveNodeName(String hostname) {
  final withoutLocal = hostname.trim().replaceFirst(
    RegExp(r'\.local$', caseSensitive: false),
    '',
  );
  final safe = withoutLocal
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  return safe.isEmpty ? fallbackNodeName : safe;
}

/// Preserves the old behaviour when the host has no usable name, so a join never
/// sends an empty `--name`.
const fallbackNodeName = 'grid-app';
