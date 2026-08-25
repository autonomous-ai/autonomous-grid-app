/// A bound on how much damage a wrong answer about firmware can do.
///
/// The three layers below this one — product-scoped framing, a greeting that
/// names its product, and letting go of a port that is not ours — all decide
/// *whether this device is mine*. This one assumes they can be wrong, and makes
/// being wrong cost one flash instead of a board.
///
/// The failure it is sized against is measured, not imagined. Grid and Harness
/// ship the same Waveshare 466×466 ESP32-S3 with the same USB identity, and each
/// side used to decide "should I update this?" from a version number — which
/// orders builds within one lineage and means nothing across two. Once the other
/// product's published version climbs past this one's, each side reflashes what
/// the other just wrote: roughly 3 MB and a reboot every 15 seconds, about
/// 700 MB an hour into a flash rated in erase cycles, with the board unusable
/// throughout and neither app seeing anything wrong.
///
/// It also covers the cases nobody wrote a layer for: a third product on this
/// board, and this app's own bugs.
library;

/// How many images this app may write to one board in an hour.
///
/// Three, because a legitimate session can genuinely need more than one — an
/// update that fails and is retried, then a second one after the user pulls a
/// newer build — and cannot plausibly need a fourth. Past that, whatever is
/// happening is not a person updating their panel.
const int kPanelFlashesPerHour = 3;

/// The window [kPanelFlashesPerHour] is counted over.
const Duration kPanelFlashWindow = Duration(hours: 1);

/// Whether this app may write an image to a board, and why not.
///
/// Keyed by MAC throughout — the board, not the port and not the session. That
/// is the whole design: **every flash ends in a reboot**, so a memory scoped to
/// a link would be cleared by the very event it exists to count. The MAC is what
/// survives it.
///
/// In memory rather than on disk, and that is a considered stop. The loop this
/// guards against runs at fifteen-second intervals, so it is long over before an
/// app restart is relevant; persisting would instead mean a user who genuinely
/// needed a fourth flash today could not get one tomorrow either, refused by a
/// file nobody knows is there.
class PanelFlashDamper {
  /// Every board-and-version this app has written, for as long as it runs.
  final _written = <String>{};

  /// When each board was written to, newest last, pruned to [kPanelFlashWindow].
  final _recent = <String, List<DateTime>>{};

  /// Why [version] must not be written to [mac], or null when it may be.
  ///
  /// Phrased as the reason rather than as a bool because the caller's only job
  /// with a refusal is to log it: a suppressed write that says nothing is
  /// indistinguishable from an update that silently never happened, which is
  /// the failure this whole area keeps producing.
  String? refuse(String mac, String version, DateTime now) {
    if (mac.isEmpty) return null;
    if (_written.contains(_key(mac, version))) {
      // The strongest rule, and the one that actually breaks a loop: a board
      // that was given this exact image and came back asking for it again did
      // not fail to receive it — either something else wrote over it, or its
      // `hello.fw` disagrees with what is in its flash. Writing it a second time
      // cannot make either of those true.
      return 'it has already been written $version once this session';
    }
    final recent = _prune(mac, now);
    if (recent.length >= kPanelFlashesPerHour) {
      return 'it has been written ${recent.length} times in the last '
          '${kPanelFlashWindow.inHours}h, which is the cap';
    }
    return null;
  }

  /// An image was written. Called on the panel's own confirmation, not on the
  /// decision to offer: an offer the panel declines costs it nothing.
  void wrote(String mac, String version, DateTime now) {
    if (mac.isEmpty) return;
    _written.add(_key(mac, version));
    _prune(mac, now).add(now);
  }

  List<DateTime> _prune(String mac, DateTime now) {
    final times = _recent.putIfAbsent(mac, () => <DateTime>[]);
    times.removeWhere((at) => now.difference(at) > kPanelFlashWindow);
    return times;
  }

  /// A space separates them, and neither half can contain one: a MAC is hex and
  /// colons, and a version string is what `esp_app_desc_t` holds.
  String _key(String mac, String version) => '$mac $version';
}
