import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_app/features/app_update/logic/app_update_controller.dart';
import 'package:grid_app/features/app_update/logic/app_update_state.dart';
import 'package:grid_app/features/app_update/logic/installer_launcher.dart';
import 'package:grid_app/infrastructure/api/app_update_client.dart';
import 'package:grid_app/infrastructure/api/models/app_version_info.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/shared/app_info.dart';

/// Deterministic, offline [AppUpdateClient] — returns canned results and records
/// how many times each call ran, so the controller's transitions can be checked
/// without touching the network.
class _FakeAppUpdateClient implements AppUpdateClient {
  _FakeAppUpdateClient({this.checkResult, this.downloadResult});

  (AppVersionInfo?, AppUpdateError?)? checkResult;
  (File?, AppUpdateError?)? downloadResult;
  int checkCalls = 0;
  int downloadCalls = 0;

  @override
  Future<(AppVersionInfo?, AppUpdateError?)> check({
    required String apiUrl,
    required String platform,
  }) async {
    checkCalls++;
    return checkResult ?? (null, const AppUpdateError('no result configured'));
  }

  @override
  Future<(File?, AppUpdateError?)> download({
    required String url,
    required File destination,
    int? expectedBytes,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    downloadCalls++;
    onProgress?.call(const DownloadProgress(doneMb: 5, totalMb: 10, pct: 50));
    return downloadResult ?? (destination, null);
  }
}

AppVersionInfo _info(
  String version, {
  String? url = 'https://dl.example/Grid.dmg',
  String? minSupported,
  bool mandatory = false,
}) {
  final key = currentPlatformKey()!;
  return AppVersionInfo(
    version: version,
    mandatory: mandatory,
    platforms: {
      if (url != null)
        key: PlatformRelease(url: url, sizeBytes: 100, minSupported: minSupported),
    },
  );
}

ProviderContainer _container({
  required AppUpdateClient client,
  String current = '0.2.0',
  InstallerLauncher? launcher,
}) {
  final container = ProviderContainer(overrides: [
    appVersionProvider.overrideWith((ref) => current),
    gridApiUrlProvider.overrideWithValue('https://example.test/'),
    appUpdateClientProvider.overrideWithValue(client),
    if (launcher != null) installerLauncherProvider.overrideWithValue(launcher),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('AppUpdateController.checkForUpdate', () {
    test('surfaces an available update when a newer build exists', () async {
      final client = _FakeAppUpdateClient(checkResult: (_info('0.3.0'), null));
      final container = _container(client: client);

      await container.read(appUpdateControllerProvider.notifier).checkForUpdate();
      final state = container.read(appUpdateControllerProvider);

      expect(state, isA<AppUpdateAvailable>());
      final available = state as AppUpdateAvailable;
      expect(available.info.version, '0.3.0');
      expect(available.release?.hasUrl, isTrue);
      expect(available.mandatory, isFalse);
      expect(client.checkCalls, 1);
    });

    test('stays idle when already on the latest version', () async {
      final client = _FakeAppUpdateClient(checkResult: (_info('0.2.0'), null));
      final container = _container(client: client);

      await container.read(appUpdateControllerProvider.notifier).checkForUpdate();

      expect(container.read(appUpdateControllerProvider), isA<AppUpdateIdle>());
    });

    test('a check error maps to a silent check failure', () async {
      final client = _FakeAppUpdateClient(
          checkResult: (null, const AppUpdateError('boom', detail: 'raw')));
      final container = _container(client: client);

      await container.read(appUpdateControllerProvider.notifier).checkForUpdate();
      final state = container.read(appUpdateControllerProvider);

      expect(state, isA<AppUpdateFailed>());
      expect((state as AppUpdateFailed).phase, AppUpdatePhase.check);
    });

    test('a build below min_supported is marked mandatory', () async {
      final client = _FakeAppUpdateClient(
          checkResult: (_info('0.3.0', minSupported: '0.2.5'), null));
      final container = _container(client: client, current: '0.1.0');

      await container.read(appUpdateControllerProvider.notifier).checkForUpdate();
      final state = container.read(appUpdateControllerProvider);

      expect((state as AppUpdateAvailable).mandatory, isTrue);
    });
  });

  group('AppUpdateController.downloadAndInstall', () {
    test('downloads then hands the installer to the OS', () async {
      File? launched;
      final client = _FakeAppUpdateClient(checkResult: (_info('0.3.0'), null));
      final container = _container(
        client: client,
        launcher: (file) async => launched = file,
      );
      final controller = container.read(appUpdateControllerProvider.notifier);

      await controller.checkForUpdate();
      await controller.downloadAndInstall();
      final state = container.read(appUpdateControllerProvider);

      expect(state, isA<AppUpdateInstalling>());
      expect(client.downloadCalls, 1);
      expect(launched, isNotNull);
    });

    test('a download error keeps the update context for retry', () async {
      final client = _FakeAppUpdateClient(
        checkResult: (_info('0.3.0'), null),
        downloadResult: (null, const AppUpdateError('network down')),
      );
      final container = _container(client: client);
      final controller = container.read(appUpdateControllerProvider.notifier);

      await controller.checkForUpdate();
      await controller.downloadAndInstall();
      final state = container.read(appUpdateControllerProvider);

      expect(state, isA<AppUpdateFailed>());
      final failed = state as AppUpdateFailed;
      expect(failed.phase, AppUpdatePhase.download);
      expect(failed.available, isNotNull);
    });
  });
}
