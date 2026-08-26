/// What [GridResolver] found — the usable `grid`, plus the trail it left getting
/// there.
///
/// The trail exists because "no grid" and "a grid this Mac can't run" look
/// identical from the outside and need completely different words: the first is
/// "install it", the second is "you downloaded the wrong build". Before this,
/// both surfaced as the same "Grid needs setup" screen with an install command
/// that fixes only one of them.
class GridResolution {
  const GridResolution({
    required this.path,
    required this.probed,
    this.wrongArchSidecar,
  });

  /// Absolute path to a usable `grid`, or null when none was found.
  final String? path;

  /// Every candidate considered, in order, each with why it was rejected. Logged
  /// on a blocked preflight and shown in the Debug tab, so "we couldn't find it"
  /// can be answered with "here is where we looked".
  final List<String> probed;

  /// A bundled sidecar this CPU cannot execute — an arm64 helper on an Intel
  /// Mac. Non-null only when that sidecar was the app's last chance: if a system
  /// `grid` answered instead, nothing is wrong and this stays null.
  final String? wrongArchSidecar;
}
