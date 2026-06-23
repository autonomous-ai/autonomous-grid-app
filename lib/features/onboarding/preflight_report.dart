/// Result of the first-run system check. `grid` is required; a container engine
/// is only needed for `network create`, so its absence is a warning, not a block.
/// See Grid_Desktop_App_Plan §II.
class PreflightReport {
  const PreflightReport({
    required this.gridAvailable,
    required this.gridVersion,
    required this.containerEngine,
  });

  final bool gridAvailable;
  final String? gridVersion;

  /// "docker", "podman", or null if neither is installed.
  final String? containerEngine;

  bool get hasContainerEngine => containerEngine != null;

  /// The app can proceed past onboarding once `grid` is usable.
  bool get canProceed => gridAvailable;
}
