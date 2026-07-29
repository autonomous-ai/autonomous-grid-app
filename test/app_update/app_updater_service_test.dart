import 'dart:ffi' show Abi;

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/app_update/logic/app_updater_service.dart';

/// Tests run with no `GRID_APPCAST_URL` dart-define — exactly the situation a
/// local / dev build is in — so `isEnabled` is false and the user-initiated
/// check must still answer.
void main() {
  group('AppUpdaterService without an update feed', () {
    test('is disabled, because no appcast feed is baked into this build', () {
      final service = AppUpdaterService();

      expect(service.isEnabled, isFalse);
    });

    test(
      'a user-initiated check answers with UpdateUnsupported, never silence',
      () async {
        final service = AppUpdaterService();
        final seen = <UpdateStatus>[];
        final sub = service.status.listen(seen.add);

        await service.checkForUpdates();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(seen, [isA<UpdateUnsupported>()]);
      },
    );

    test('replays the last outcome to a late subscriber', () async {
      final service = AppUpdaterService();

      await service.checkForUpdates();
      final replayed = await service.status.first;

      expect(replayed, isA<UpdateUnsupported>());
    });

    test("Sparkle's second word on a check that found nothing is ignored — it "
        'restates "no update" down the error channel as `You\'re up to date!`, '
        'which showed as a red "Couldn\'t check for updates"', () async {
      final service = AppUpdaterService();
      final seen = <UpdateStatus>[];
      final sub = service.status.listen(seen.add);

      service.onUpdaterUpdateNotAvailable(null);
      service.onUpdaterError(UpdaterError("You're up to date!"));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [isA<UpdateUpToDate>()]);
    });

    test('an update being available also stands, whatever trails it', () async {
      final service = AppUpdaterService();
      final seen = <UpdateStatus>[];
      final sub = service.status.listen(seen.add);

      service.onUpdaterUpdateAvailable(null);
      service.onUpdaterError(UpdaterError('anything'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [isA<UpdateAvailable>()]);
    });

    test('a check that fails outright still reports the failure', () async {
      final service = AppUpdaterService();
      final seen = <UpdateStatus>[];
      final sub = service.status.listen(seen.add);

      service.onUpdaterError(UpdaterError('the feed is unreachable'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [isA<UpdateFailed>()]);
      expect((seen.single as UpdateFailed).message, 'the feed is unreachable');
    });

    test('a silent launch check stays silent', () async {
      final service = AppUpdaterService();
      final seen = <UpdateStatus>[];
      final sub = service.status.listen(seen.add);

      await service.checkInBackground();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, isEmpty);
    });
  });

  group('picking the appcast feed for this Mac', () {
    const template =
        'https://example.com/releases/latest/download/appcast-{arch}.xml';

    test('an Apple Silicon Mac polls the arm64 feed', () {
      expect(
        resolveAppcastArch(template, Abi.macosArm64),
        'https://example.com/releases/latest/download/appcast-arm64.xml',
      );
    });

    test('an Intel Mac polls the x86_64 feed — never the arm64 DMG, whose '
        'sidecar could not run there', () {
      expect(
        resolveAppcastArch(template, Abi.macosX64),
        'https://example.com/releases/latest/download/appcast-x86_64.xml',
      );
    });

    test('an unexpected arch falls back to x86_64, the slice that runs on both '
        'Macs', () {
      expect(resolveAppcastArch(template, Abi.linuxX64), contains('x86_64'));
    });

    test('a URL with no token (an older build) is left exactly as baked', () {
      const plain = 'https://example.com/releases/latest/download/appcast.xml';
      expect(resolveAppcastArch(plain, Abi.macosArm64), plain);
    });
  });
}
