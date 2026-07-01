import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/app_update_client.dart';
import '../../../infrastructure/providers.dart';
import '../../../shared/app_info.dart';
import 'app_update_state.dart';
import 'installer_launcher.dart';
import 'version_compare.dart';

/// The app-update HTTP seam. Overridden with a fake in tests.
final appUpdateClientProvider =
    Provider<AppUpdateClient>((ref) => const HttpAppUpdateClient());

/// Hands a downloaded installer to the OS. Overridden with a no-op in tests so
/// the download→install path can be exercised without spawning processes.
final installerLauncherProvider =
    Provider<InstallerLauncher>((ref) => launchInstaller);

/// Drives the app-update flow surfaced by `AppUpdateBanner`.
final appUpdateControllerProvider =
    NotifierProvider<AppUpdateController, AppUpdateState>(
        AppUpdateController.new);

/// Orchestrates the update lifecycle: check the control plane for a newer build,
/// download its installer with progress, then hand off to the OS installer.
/// Failures map to a sealed [AppUpdateFailed] with a friendly message; a
/// background check that fails stays silent (the banner hides check errors).
class AppUpdateController extends Notifier<AppUpdateState> {
  bool _autoChecked = false;
  bool _cancelDownload = false;

  @override
  AppUpdateState build() {
    ref.onDispose(() => _cancelDownload = true);
    return const AppUpdateIdle();
  }

  /// Once-per-session background check, fired from the app shell. A no-op after
  /// the first run or while a check/update is already in flight.
  Future<void> autoCheck() async {
    if (_autoChecked || state is! AppUpdateIdle) return;
    _autoChecked = true;
    await checkForUpdate();
  }

  /// Asks the control plane whether a newer build exists. Sets
  /// [AppUpdateAvailable] when one does, [AppUpdateIdle] when up to date, and
  /// [AppUpdateFailed] (phase `check`) on error.
  Future<void> checkForUpdate() async {
    if (state is AppUpdateChecking || state is AppUpdateDownloading) return;

    final platform = currentPlatformKey();
    if (platform == null) {
      state = const AppUpdateIdle(); // no builds served for this OS
      return;
    }

    state = const AppUpdateChecking();
    final current = await ref.read(appVersionProvider.future);
    final apiUrl = ref.read(gridApiUrlProvider);
    final (info, error) = await ref
        .read(appUpdateClientProvider)
        .check(apiUrl: apiUrl, platform: platform);

    if (error != null) {
      state = AppUpdateFailed(
        message: error.message,
        phase: AppUpdatePhase.check,
        detail: error.detail,
      );
      return;
    }
    if (info == null ||
        info.version.isEmpty ||
        !isNewerVersion(current: current, latest: info.version)) {
      state = const AppUpdateIdle();
      return;
    }

    final release = info.releaseFor(platform);
    final hasAsset = release?.hasUrl ?? false;
    final floor = release?.minSupported;
    final mandatory = info.mandatory ||
        (floor != null && floor.isNotEmpty && isNewerVersion(current: current, latest: floor));

    state = AppUpdateAvailable(
      info: info,
      currentVersion: current,
      release: hasAsset ? release : null,
      mandatory: mandatory,
    );
  }

  /// Downloads the installer for the available (or previously-failed) update,
  /// reporting progress, then hands it to the OS. No-op unless there's an update
  /// with a downloadable asset.
  Future<void> downloadAndInstall() async {
    final available = _availableContext();
    final release = available?.release;
    if (available == null || release == null || !release.hasUrl) return;

    _cancelDownload = false;
    state = AppUpdateDownloading(available: available);

    final dir = await Directory.systemTemp.createTemp('grid_update');
    final destination = File('${dir.path}/${_fileName(release.url)}');
    final (file, error) = await ref.read(appUpdateClientProvider).download(
          url: release.url,
          destination: destination,
          expectedBytes: release.sizeBytes,
          onProgress: (progress) {
            if (state is AppUpdateDownloading) {
              state = AppUpdateDownloading(available: available, progress: progress);
            }
          },
          isCancelled: () => _cancelDownload,
        );

    if (_cancelDownload) {
      state = available; // back to the offer
      return;
    }
    if (error != null || file == null) {
      state = AppUpdateFailed(
        message: error?.message ?? "Couldn't download the update.",
        phase: AppUpdatePhase.download,
        available: available,
        detail: error?.detail,
      );
      return;
    }

    await _install(available, file);
  }

  Future<void> _install(AppUpdateAvailable available, File file) async {
    try {
      await ref.read(installerLauncherProvider)(file);
      state = AppUpdateInstalling(info: available.info, file: file);
    } on Object catch (e) {
      state = AppUpdateFailed(
        message: "Couldn't open the installer. Try again, or download the update manually.",
        phase: AppUpdatePhase.install,
        available: available,
        detail: '$e',
      );
    }
  }

  /// Aborts an in-flight download; the banner returns to the update offer.
  void cancelDownload() {
    if (state is! AppUpdateDownloading) return;
    _cancelDownload = true;
  }

  /// Dismisses a non-mandatory update until the next launch. The banner hides
  /// the dismiss action for mandatory updates, so this only reaches idle states.
  void dismiss() => state = const AppUpdateIdle();

  /// The update context to act on — the current offer, or the one carried
  /// forward by a failed download/install so a retry has its download URL.
  AppUpdateAvailable? _availableContext() => switch (state) {
        AppUpdateAvailable s => s,
        AppUpdateFailed(:final available) => available,
        _ => null,
      };

  static String _fileName(String url) {
    final segments = Uri.tryParse(url)?.pathSegments;
    final last = (segments != null && segments.isNotEmpty) ? segments.last : '';
    return last.isNotEmpty ? last : 'grid-update-installer';
  }
}
