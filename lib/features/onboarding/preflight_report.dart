/// Why the app can't drive `grid` — the one thing it depends on. Each case gets
/// its own words and its own next step on the preflight screen, because "not
/// installed", "wrong build for this Mac" and "installed but won't run" are
/// three different problems and only one of them is fixed by installing it.
sealed class PreflightIssue {
  const PreflightIssue();

  /// A short technical line for the log and the Debug tab — never user copy.
  String get summary;
}

/// No `grid` anywhere: no sidecar in this app bundle, nothing on the system.
class GridMissing extends PreflightIssue {
  const GridMissing(this.probed);

  /// Every path the resolver looked at, each with why it was rejected.
  final List<String> probed;

  @override
  String get summary => 'no grid found (${probed.length} paths probed)';
}

/// The app bundles a helper this Mac's CPU cannot execute — i.e. the user has
/// the wrong download (an Apple Silicon DMG on an Intel Mac, or the reverse on
/// a Mac without Rosetta). The helper is right there; telling them to install
/// one is the wrong instruction.
class GridWrongArch extends PreflightIssue {
  const GridWrongArch(this.sidecarPath);

  final String sidecarPath;

  @override
  String get summary => 'bundled sidecar is for another CPU: $sidecarPath';
}

/// `grid` was found but is unusable: it wouldn't start, timed out, or is older
/// than the app can drive. [message] is already in the app's voice.
class GridUnusable extends PreflightIssue {
  const GridUnusable(this.message);

  final String message;

  @override
  String get summary => message;
}

/// Result of the first-run system check. Only `grid` is required — the app
/// talks to the hosted relay/API, not a local container engine. See
/// Grid_Desktop_App_Plan §II.
class PreflightReport {
  /// `grid` is present and ran. [gridVersion] is display-only and may be null:
  /// a build without package metadata exits 0 without printing one.
  const PreflightReport.ready(this.gridVersion) : issue = null;

  /// The app cannot proceed, and [issue] says why.
  const PreflightReport.blocked(PreflightIssue this.issue, {this.gridVersion});

  final String? gridVersion;

  /// Null exactly when the app can proceed.
  final PreflightIssue? issue;

  /// The app can proceed past onboarding once `grid` is usable.
  bool get canProceed => issue == null;
}
