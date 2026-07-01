import 'dart:io';

import '../../../infrastructure/api/models/app_version_info.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart';

/// Which step failed, so the banner can offer the right retry and message.
enum AppUpdatePhase { check, download, install }

/// The manifest platform key for the host OS, or null on an OS the update feed
/// doesn't serve builds for.
String? currentPlatformKey() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return null;
}

/// The app-update lifecycle as an exhaustive sealed hierarchy (no boolean soup):
/// `idle → checking → (available → downloading → installing) | idle | failed`.
sealed class AppUpdateState {
  const AppUpdateState();
}

/// Nothing to show — not yet checked, dismissed, or already up to date.
class AppUpdateIdle extends AppUpdateState {
  const AppUpdateIdle();
}

/// A version check is in flight. Silent: the banner stays hidden so a routine
/// background check never flickers UI.
class AppUpdateChecking extends AppUpdateState {
  const AppUpdateChecking();
}

/// A newer build exists. [release] is null when the server published [info] but
/// has no downloadable asset for this platform yet (info-only, no auto-install).
class AppUpdateAvailable extends AppUpdateState {
  const AppUpdateAvailable({
    required this.info,
    required this.currentVersion,
    required this.release,
    required this.mandatory,
  });

  final AppVersionInfo info;
  final String currentVersion;
  final PlatformRelease? release;

  /// Server-forced or below the supported floor — the user can't dismiss it.
  final bool mandatory;
}

/// The installer is downloading. [progress] is null until the first byte lands.
class AppUpdateDownloading extends AppUpdateState {
  const AppUpdateDownloading({
    required this.available,
    this.progress,
  });

  final AppUpdateAvailable available;
  final DownloadProgress? progress;

  AppVersionInfo get info => available.info;
  bool get mandatory => available.mandatory;
}

/// The installer downloaded and was handed off to the OS. The user finishes in
/// the mounted image / setup wizard, then quits Grid so it can be replaced.
class AppUpdateInstalling extends AppUpdateState {
  const AppUpdateInstalling({required this.info, required this.file});

  final AppVersionInfo info;
  final File file;
}

/// A step failed with a user-facing [message]; [phase] says which so the banner
/// retries the right action. [available] carries the update context forward
/// (non-null once we know an update exists) so a failed download can retry.
class AppUpdateFailed extends AppUpdateState {
  const AppUpdateFailed({
    required this.message,
    required this.phase,
    this.available,
    this.detail,
  });

  final String message;
  final AppUpdatePhase phase;
  final AppUpdateAvailable? available;
  final String? detail;
}
