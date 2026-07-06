import 'dart:io';

import 'package:flutter/foundation.dart';

/// Which backend the app — and the `grid` CLI it spawns — talks to.
///
/// **Dev** points the whole app at staging via two overrides, resolved in this
/// order (both dev-only):
///   1. `--dart-define` (compile-time) — works no matter how the app is launched
///      (terminal, VS Code Run, IDE), so this is the reliable one:
///      ```sh
///      flutter run -d macos \
///        --dart-define=GRID_CONTROL_PLANE_URL=https://api-grid.autonomousdev.xyz \
///        --dart-define=GRID_WEBSITE_URL=https://staging.autonomousdev.xyz
///      ```
///   2. process env vars (`export ...` before `flutter run`) — the same vars the
///      `grid` CLI reads. Only reaches the app when it inherits the shell env
///      (i.e. launched from that terminal); a Run-button/Finder launch won't.
///
/// Whichever is set, the resolved values are also forwarded into the spawned
/// `grid` CLI's environment, so app + CLI always hit the same backend.
///
/// **Release builds always use production.** Both overrides are ignored under
/// [kReleaseMode], so a shipped `flutter build` can never reach staging — even
/// if built with the defines or launched from a shell that exports the vars.
class AppEnvironment {
  AppEnvironment._();

  /// Env var / dart-define names the `grid` CLI also reads; the app forwards the
  /// same overrides so the two never disagree on which backend they hit.
  static const controlPlaneEnvKey = 'GRID_CONTROL_PLANE_URL';
  static const websiteEnvKey = 'GRID_WEBSITE_URL';

  // Compile-time `--dart-define` values (empty string when not passed). Must use
  // literal names — `String.fromEnvironment` requires a const literal argument.
  static const _controlPlaneDefine =
      String.fromEnvironment('GRID_CONTROL_PLANE_URL');
  static const _websiteDefine = String.fromEnvironment('GRID_WEBSITE_URL');

  static const _prodControlPlaneUrl = 'https://api-grid.autonomous.ai/';
  static const _prodWebsiteUrl = 'https://grid.autonomous.ai';

  /// Control-plane (Hermes) base URL for the app's own HTTP calls. Staging
  /// override honoured only in dev; release is pinned to prod.
  static String get controlPlaneUrl =>
      _devOverride(controlPlaneEnvKey) ?? _prodControlPlaneUrl;

  /// Marketing/help website base URL (the preflight help link + install
  /// command). Trailing slashes are trimmed so callers can append cleanly.
  static String get websiteUrl =>
      (_devOverride(websiteEnvKey) ?? _prodWebsiteUrl).replaceFirst(
        RegExp(r'/+$'),
        '',
      );

  /// True when a dev override is pointing the app at a non-prod backend — use it
  /// to surface a "you're on staging" hint in the UI if desired.
  static bool get isStagingOverride => _devOverride(controlPlaneEnvKey) != null;

  /// The overrides to forward into the spawned `grid` CLI's environment, so the
  /// CLI targets the same backend as the app. Empty in release (build = prod).
  static Map<String, String> cliEnvOverrides() {
    final overrides = <String, String>{};
    final controlPlane = _devOverride(controlPlaneEnvKey);
    if (controlPlane != null) overrides[controlPlaneEnvKey] = controlPlane;
    final website = _devOverride(websiteEnvKey);
    if (website != null) overrides[websiteEnvKey] = website;
    return overrides;
  }

  /// Resolves [key]'s override — `--dart-define` first, then the process env —
  /// but only outside release builds. Null when neither is set or when running a
  /// release build (build always uses prod).
  static String? _devOverride(String key) {
    if (kReleaseMode) return null;
    final define = switch (key) {
      controlPlaneEnvKey => _controlPlaneDefine,
      websiteEnvKey => _websiteDefine,
      _ => '',
    };
    if (define.isNotEmpty) return define;
    final value = Platform.environment[key];
    return (value != null && value.isNotEmpty) ? value : null;
  }
}
