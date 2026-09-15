import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/phone/logic/phone_pairing_controller.dart';
import 'package:grid_app/infrastructure/pairing_host/device_registry.dart';
import 'package:grid_app/infrastructure/pairing_host/host_identity_store.dart';
import 'package:grid_app/shared/app_info.dart';

/// The screen's controller, driven without a relay.
///
/// The happy path is proved end to end by `tool/pairing_host.dart` against a
/// running cell — it needs two processes and a socket, which is exactly what
/// does not belong in this suite. What belongs here is everything around it:
/// the states the screen switches on, and the sentence a person is shown when
/// the relay is not there.
void main() {
  late Directory home;
  late ProviderContainer container;

  setUp(() {
    home = Directory.systemTemp.createTempSync('grid-phone-');
    container = ProviderContainer(
      overrides: [
        hostIdentityStoreProvider.overrideWithValue(
          HostIdentityStore(file: File('${home.path}/identity.json')),
        ),
        deviceRegistryProvider.overrideWithValue(
          DeviceRegistry(file: File('${home.path}/devices.json')),
        ),
        appVersionProvider.overrideWith((ref) async => '0.0.0-test'),
      ],
    );
    // Riverpod 3 pauses a provider nothing listens to, and this controller
    // publishes from socket callbacks — a listener is what keeps it awake.
    container.listen(phonePairingProvider, (_, _) {});
  });

  tearDown(() {
    container.dispose();
    home.deleteSync(recursive: true);
  });

  PhonePairingController controller() =>
      container.read(phonePairingProvider.notifier);

  test('nothing about this computer is announced until someone asks, so the '
      'screen opens off rather than dialling a relay on launch', () {
    expect(container.read(phonePairingProvider), isA<PhonePairingOff>());
  });

  test('a relay that is not there is reported as a place to start one, not as '
      'an exception', () async {
    // Port 1 on loopback: refused immediately, and never leaves the machine.
    await controller().start('ws://127.0.0.1:1');

    final state = container.read(phonePairingProvider);
    expect(state, isA<PhonePairingFailed>());
    final message = (state as PhonePairingFailed).message;
    expect(message, contains('ws://127.0.0.1:1'));
    expect(message, contains('Start one'));
    // Whatever it says, it must not be a stack trace.
    expect(message, isNot(contains('#0')));
  });

  test('a failure leaves the identity file behind, so trying again does not '
      'mint a second key and strand the phones paired to the first', () async {
    await controller().start('ws://127.0.0.1:1');
    final first = await container
        .read(hostIdentityStoreProvider)
        .loadOrCreate();

    await controller().start('ws://127.0.0.1:1');
    final second = await container
        .read(hostIdentityStoreProvider)
        .loadOrCreate();

    expect(second.publicKey, first.publicKey);
  });

  test('a code cannot be minted while the link is down, because the token it '
      'would carry names a relay session that does not exist', () async {
    await controller().createCode('My phone');

    expect(container.read(phonePairingProvider), isA<PhonePairingOff>());
    expect(await container.read(deviceRegistryProvider).load(), isEmpty);
  });

  test('revoking works whether or not a relay is reachable — a lost phone is '
      'not a thing to wait on a server for', () async {
    final registry = container.read(deviceRegistryProvider);
    final phone = await registry.register('Lost phone');

    await controller().revoke(phone.deviceId);

    expect(await registry.authenticate(phone.token), isNull);
  });
}
