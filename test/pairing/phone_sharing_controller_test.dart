import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/phone/logic/phone_sharing_controller.dart';
import 'package:grid_app/features/phone/logic/phone_sharing_state.dart';
import 'package:grid_app/features/phone/logic/phone_tunnel_controller.dart';
import 'package:grid_app/infrastructure/pairing_host/cloudflared_tunnel.dart';
import 'package:grid_app/infrastructure/pairing_host/device_registry.dart';
import 'package:grid_app/infrastructure/pairing_host/host_identity_store.dart';
import 'package:grid_app/infrastructure/pairing_host/phone_link_prefs.dart';
import 'package:grid_app/shared/app_info.dart';
import 'package:grid_pairing/grid_pairing.dart';

import 'locator_fakes.dart';

/// Sharing with a phone, driven without Cloudflare.
///
/// The three things that have to be true together — a server listening, an
/// address in front of it, and that address published where the phone will look
/// — are what this file is about. Two of them are testable offline exactly as
/// they run; the third is a process, so the tunnel is a fake and everything it
/// hands back is the real thing.
///
/// What the assertions come back to, again and again, is the record a phone
/// would read. A wrong one there is not a visible failure anywhere: the phone
/// simply says the computer cannot be reached.
void main() {
  late Directory home;
  late ProviderContainer container;
  late FakeLocatorTransport locator;
  late _FakeTunnel tunnel;

  setUp(() {
    home = Directory.systemTemp.createTempSync('grid-phone-');
    locator = FakeLocatorTransport();
    tunnel = _FakeTunnel();
    container = ProviderContainer(
      overrides: [
        hostIdentityStoreProvider.overrideWithValue(
          HostIdentityStore(file: File('${home.path}/identity.json')),
        ),
        deviceRegistryProvider.overrideWithValue(
          DeviceRegistry(file: File('${home.path}/devices.json')),
        ),
        phoneLinkPrefsProvider.overrideWithValue(
          PhoneLinkPrefs(file: File('${home.path}/phone_link.json')),
        ),
        locatorClientProvider.overrideWithValue(
          LocatorClient(send: locator.send),
        ),
        phoneTunnelProvider.overrideWith(() => tunnel),
        appVersionProvider.overrideWith((ref) async => '0.0.0-test'),
      ],
    );
    // Riverpod 3 pauses a provider nothing listens to, and this controller has
    // to hear its own tunnel die — a listener is what keeps it awake.
    container.listen(phoneSharingProvider, (_, _) {});
  });

  tearDown(() async {
    await container.read(phoneSharingProvider.notifier).stop();
    container.dispose();
    home.deleteSync(recursive: true);
  });

  PhoneSharingController controller() =>
      container.read(phoneSharingProvider.notifier);

  DeviceRegistry registry() => container.read(deviceRegistryProvider);

  PhoneSharingState now() => container.read(phoneSharingProvider);

  test('a computer that has never shared opens no port and publishes nothing, '
      'however many times Grid is launched', () async {
    await controller().resume();

    expect(now(), isA<PhoneSharingOff>());
    expect(locator.calls, isEmpty);
  });

  test(
    'sharing comes back by itself if somebody had switched it on, because '
    'from the phone a computer that forgot looks like one that is asleep',
    () async {
      await container.read(phoneLinkPrefsProvider).write(on: true);

      await controller().resume();

      expect(now(), isA<PhoneSharingLive>());
    },
  );

  test(
    'a phone is told where this computer is, which key to expect and what to '
    'call it — everything it needs, under the code it holds',
    () async {
      await controller().start();
      await controller().addPhone('My phone');

      final device = (await registry().load()).single;
      final token = PairToken.tryParse(device.token)!;
      final record = locator.recordFor(token);

      expect(record, isNotNull);
      expect(record!.cellUrl, 'wss://first-address.trycloudflare.com');
      expect(record.hostName, Platform.localHostname);
      expect(
        record.relayHostId,
        deriveRelayHostId(
          (await container.read(hostIdentityStoreProvider).loadOrCreate())
              .publicKey,
        ),
      );
      expect(
        record.hostPublicKey,
        (await container.read(hostIdentityStoreProvider).loadOrCreate())
            .publicKey,
      );
    },
  );

  test('each phone gets its own code and its own document, so revoking one '
      'leaves the others working', () async {
    await controller().start();
    await controller().addPhone('Mine');
    await controller().addPhone('Theirs');

    final devices = await registry().load();
    final first = PairToken.tryParse(devices.first.token)!;
    final second = PairToken.tryParse(devices.last.token)!;

    expect(first, isNot(second));
    expect(first.locatorDocId, isNot(second.locatorDocId));
    expect(locator.recordFor(first), isNotNull);
    expect(locator.recordFor(second), isNotNull);

    await controller().revoke(devices.first.deviceId);

    expect(locator.recordFor(first), isNull);
    expect(locator.recordFor(second), isNotNull);
    expect(await registry().authenticate(devices.first.token), isNull);
    expect(await registry().authenticate(devices.last.token), isNotNull);
  });

  test('a phone may only read until somebody says otherwise, at the computer — '
      'a code proves which device, never who is holding it', () async {
    await controller().start();
    await controller().addPhone('My phone');

    final device = (await registry().load()).single;
    expect(device.mayAct, isFalse);

    await controller().setMayAct(device.deviceId, true);

    expect((await registry().load()).single.mayAct, isTrue);
  });

  test(
    'the address a phone was told is replaced when the tunnel moves, which a '
    'quick tunnel does with no warning and no promise not to',
    () async {
      await controller().start();
      await controller().addPhone('My phone');
      final token = PairToken.tryParse((await registry().load()).single.token)!;
      expect(
        locator.recordFor(token)!.cellUrl,
        'wss://first-address.trycloudflare.com',
      );

      tunnel.url = 'https://second-address.trycloudflare.com';
      tunnel.die();
      await pumpEventQueue();

      expect(
        locator.recordFor(token)!.cellUrl,
        'wss://second-address.trycloudflare.com',
      );
      expect(
        (now() as PhoneSharingLive).publicUrl,
        'https://second-address.trycloudflare.com',
      );
    },
  );

  test(
    'a tunnel that will not open is reported as itself and left switched '
    'off, so the next launch does not reopen something that never came up',
    () async {
      tunnel.failure = 'Cloudflare did not answer.';

      await controller().start();

      expect(now(), isA<PhoneSharingFailed>());
      expect(
        (now() as PhoneSharingFailed).message,
        'Cloudflare did not answer.',
      );
      expect(await container.read(phoneLinkPrefsProvider).isOn(), isFalse);
    },
  );

  test('turning sharing off is remembered, because it is the one thing that '
      'must not undo itself on the next launch', () async {
    await controller().start();

    await controller().stop();

    expect(now(), isA<PhoneSharingOff>());
    expect(await container.read(phoneLinkPrefsProvider).isOn(), isFalse);
    expect(container.read(phoneTunnelProvider), isA<TunnelOff>());
  });

  test('a phone cannot be added while sharing is off: the code would name an '
      'address that does not exist yet', () async {
    await controller().addPhone('My phone');

    expect(await registry().load(), isEmpty);
    expect(locator.calls, isEmpty);
  });

  test(
    'a locator that refuses the write still leaves the computer serving, and '
    'says so rather than pretending the phone is ready',
    () async {
      await controller().start();
      locator.status = 403;

      await controller().addPhone('My phone');

      expect(now(), isA<PhoneSharingLive>());
      final live = now() as PhoneSharingLive;
      // The phone is registered — it just has not been told where to look — so
      // the code is not shown as though it were ready to type in.
      expect(live.devices, hasLength(1));
      expect(live.newest, isNull);
      expect(live.events.last, contains('rules'));
    },
  );

  test('a failure leaves the identity file behind, so trying again does not '
      'mint a second key and strand every phone paired to the first', () async {
    tunnel.failure = 'nope';
    await controller().start();
    final first = await container
        .read(hostIdentityStoreProvider)
        .loadOrCreate();

    await controller().start();
    final second = await container
        .read(hostIdentityStoreProvider)
        .loadOrCreate();

    expect(second.publicKey, first.publicKey);
  });
}

/// The tunnel, without Cloudflare.
///
/// Subclasses the real controller rather than replacing the provider's type, so
/// the code under test calls exactly the methods it calls in production and the
/// state it reads is the real sealed type.
class _FakeTunnel extends PhoneTunnelController {
  /// The address the next open hands back.
  String url = 'https://first-address.trycloudflare.com';

  /// When set, opening fails with this message instead.
  String? failure;

  /// Every port it was pointed at, so a test can prove it was the cell's.
  final opened = <int>[];

  @override
  TunnelState build() => const TunnelOff();

  @override
  Future<void> open(int port) async {
    opened.add(port);
    final problem = failure;
    state = problem != null ? TunnelFailed(problem) : TunnelOpen(url: url);
  }

  @override
  Future<void> close() async => state = const TunnelOff();

  /// What Cloudflare withdrawing a quick tunnel looks like from in here.
  void die() => state = const TunnelFailed('The address closed.');
}
