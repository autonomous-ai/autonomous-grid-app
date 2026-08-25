import 'analytics_service.dart';

/// The events this app sends, one method each.
///
/// An extension rather than a set of loose helpers, so every [Analytics]
/// implementation gets them for free — and so the name and the params of an
/// event are written down **once**. Two call sites that name the same action
/// differently is the failure mode this exists to prevent; it is the same rule
/// the app already follows for user-facing copy (conventions §5).
///
/// Adding an event: add a method here, keep the name `snake_case`, and keep the
/// params to product facts — never message text, prompts, file contents or
/// paths. This stream describes what someone did, not what they wrote.
extension AnalyticsEvents on Analytics {
  /// The app came up. [signedIn] separates a returning user from someone who
  /// is about to meet the login screen.
  void appOpened({required bool signedIn}) =>
      track('app_opened', params: {'signed_in': signedIn});

  /// The app is quitting, after [open]. Sent on the way out, so it is the last
  /// thing the queue drains.
  void appClosed({required Duration open}) =>
      track('app_closed', params: {'open_seconds': open.inSeconds});

  /// A screen was opened. [screen] is the section's stable name, never its
  /// label — labels are rewritten weekly and a renamed label would read as a
  /// new screen.
  void screenView(String screen) =>
      track('screen_view', params: {'screen': screen});

  /// Sign-in completed.
  void signedIn() => track('signed_in');

  /// Sign-in didn't complete. [reason] is a short code — `timeout`,
  /// `cli_missing`, `failed` — never the error text, which can carry a path or
  /// a host name.
  void signInFailed(String reason) =>
      track('sign_in_failed', params: {'reason': reason});

  /// The user signed out.
  void signedOut() => track('signed_out');
}
