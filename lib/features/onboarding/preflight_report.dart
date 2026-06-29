/// Result of the first-run system check. Only `grid` is required — the app
/// talks to the hosted relay/API, not a local container engine. See
/// Grid_Desktop_App_Plan §II.
class PreflightReport {
  const PreflightReport({
    required this.gridAvailable,
    required this.gridVersion,
    this.gridError,
  });

  final bool gridAvailable;
  final String? gridVersion;

  /// Why `grid` didn't run, when it's installed but failed (e.g. a missing
  /// dependency). Null when `grid` is simply absent or working.
  final String? gridError;

  /// The app can proceed past onboarding once `grid` is usable.
  bool get canProceed => gridAvailable;
}
