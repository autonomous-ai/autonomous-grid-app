// Pure, side-effect-free semantic-version comparison used by the app-update
// check. Kept out of the controller so it can be exhaustively unit-tested.

/// Compares two dotted versions (`0.3.0`, `1.2`, `0.2.0-beta.1`). Returns a
/// negative number when [a] < [b], zero when equal, a positive number when
/// [a] > [b].
///
/// Build metadata (`+…`) is ignored. A pre-release (`-…`) sorts *below* the same
/// core version (`0.3.0-rc1` < `0.3.0`), per semver. Non-numeric segments are
/// treated as `0` so a malformed value never throws — it just compares low.
int compareVersions(String a, String b) {
  final (aCore, aPre) = _split(a);
  final (bCore, bPre) = _split(b);

  final maxLen = aCore.length > bCore.length ? aCore.length : bCore.length;
  for (var i = 0; i < maxLen; i++) {
    final av = i < aCore.length ? aCore[i] : 0;
    final bv = i < bCore.length ? bCore[i] : 0;
    if (av != bv) return av < bv ? -1 : 1;
  }

  // Cores are equal: a version *with* a pre-release tag ranks below one without.
  if (aPre == bPre) return 0;
  if (aPre == null) return 1;
  if (bPre == null) return -1;
  return aPre.compareTo(bPre);
}

/// True when [latest] is a strictly newer version than [current].
bool isNewerVersion({required String current, required String latest}) =>
    compareVersions(latest, current) > 0;

/// Splits a version into its numeric core segments and optional pre-release tag,
/// dropping any `+build` metadata.
(List<int>, String?) _split(String version) {
  final trimmed = version.trim();
  final noBuild = _before(trimmed, '+');
  final dash = noBuild.indexOf('-');
  final core = dash == -1 ? noBuild : noBuild.substring(0, dash);
  final pre = dash == -1 ? null : noBuild.substring(dash + 1);
  final segments = core
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList(growable: false);
  return (segments, pre);
}

String _before(String value, String marker) {
  final i = value.indexOf(marker);
  return i == -1 ? value : value.substring(0, i);
}
