import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/device_registry.dart';

/// Per-device tokens are what make "revoke this phone" mean anything. With one
/// shared secret the only remedy is re-pairing everything, which in practice
/// means nobody ever revokes.
void main() {
  late Directory home;
  late DeviceRegistry registry;

  setUp(() {
    home = Directory.systemTemp.createTempSync('grid-devices-');
    registry = DeviceRegistry(file: File('${home.path}/paired_devices.json'));
  });
  tearDown(() => home.deleteSync(recursive: true));

  test(
    'a registered phone can authenticate and an unknown token cannot',
    () async {
      final phone = await registry.register('My phone');

      expect(
        (await registry.authenticate(phone.token))?.deviceId,
        phone.deviceId,
      );
      expect(await registry.authenticate('not-the-token'), isNull);
      expect(await registry.authenticate(''), isNull);
    },
  );

  test('the file holding the tokens is owner-readable only', () async {
    await registry.register('My phone');
    if (Platform.isWindows) return;

    final mode = File(
      '${home.path}/paired_devices.json',
    ).statSync().modeString();
    expect(mode.substring(3), '------', reason: 'mode was $mode');
  });

  test('two phones get different tokens, so one being taken does not hand over '
      'the other', () async {
    final first = await registry.register('Mine');
    final second = await registry.register('Theirs');

    expect(second.token, isNot(first.token));
    expect(second.deviceId, isNot(first.deviceId));
    expect(await registry.load(), hasLength(2));
  });

  test('revoking one phone leaves every other one working — the whole reason '
      'the tokens are separate', () async {
    final keep = await registry.register('Keep');
    final lost = await registry.register('Lost');

    await registry.revoke(lost.deviceId);

    expect(await registry.authenticate(lost.token), isNull);
    expect((await registry.authenticate(keep.token))?.deviceId, keep.deviceId);
  });

  test(
    'pairing the same phone twice leaves two credentials, because revoking '
    'the code someone read over your shoulder must not log you out',
    () async {
      final older = await registry.register('My phone');
      final newer = await registry.register('My phone');

      await registry.revoke(older.deviceId);

      expect(await registry.authenticate(older.token), isNull);
      expect(await registry.authenticate(newer.token), isNotNull);
    },
  );

  test('a phone that has never connected is distinguishable from one that has, '
      'so the screen can say which code was never used', () async {
    final phone = await registry.register('My phone');
    expect(phone.everConnected, isFalse);

    await registry.markSeen(phone.deviceId);

    final seen = (await registry.load()).single;
    expect(seen.everConnected, isTrue);
    expect(seen.lastSeenAtMs, greaterThan(0));
    expect(seen.pairedAtMs, phone.pairedAtMs);
  });

  test(
    'marking an unknown device changes nothing rather than inventing a row',
    () async {
      await registry.register('My phone');
      await registry.markSeen('no-such-device');

      expect(await registry.load(), hasLength(1));
    },
  );

  test('a corrupt or absent file reads as no phones, never as a crash — a '
      'computer with no paired devices is a normal state', () async {
    expect(await registry.load(), isEmpty);

    File('${home.path}/paired_devices.json').writeAsStringSync('{ nope');
    expect(await registry.load(), isEmpty);

    // And it is still usable afterwards: the bad file is replaced on the next
    // write rather than wedging pairing forever.
    final phone = await registry.register('My phone');
    expect(await registry.authenticate(phone.token), isNotNull);
  });

  group('whether a phone may make this computer act', () {
    test('is off for a phone that has just paired, because a pairing code '
        'proves which device is calling and not who is holding it', () async {
      final phone = await registry.register('My phone');

      expect(phone.mayAct, isFalse);
      expect((await registry.load()).single.mayAct, isFalse);
    });

    test('survives being written and read back, so the grant is a decision '
        'made once rather than one that quietly lapses', () async {
      final phone = await registry.register('My phone');

      await registry.setMayAct(phone.deviceId, true);
      expect((await registry.load()).single.mayAct, isTrue);

      await registry.setMayAct(phone.deviceId, false);
      expect((await registry.load()).single.mayAct, isFalse);
    });

    test('is not granted by a registry written before the flag existed — an '
        'older file must not read as permission', () async {
      File('${home.path}/paired_devices.json').writeAsStringSync(
        jsonEncode({
          'v': 1,
          'devices': [
            {
              'deviceId': 'old',
              'name': 'An older phone',
              'token': 'a' * 48,
              'pairedAt': 1,
              'lastSeenAt': 2,
            },
          ],
        }),
      );

      expect((await registry.load()).single.mayAct, isFalse);
    });

    test('granting one phone leaves the others alone, which is the reason '
        'each device has its own record at all', () async {
      final first = await registry.register('Mine');
      await registry.register('Someone else\'s');

      await registry.setMayAct(first.deviceId, true);

      final devices = await registry.load();
      expect(
        devices.firstWhere((d) => d.deviceId == first.deviceId).mayAct,
        isTrue,
      );
      expect(
        devices.where((d) => d.deviceId != first.deviceId).single.mayAct,
        isFalse,
      );
    });

    test(
      'a revoked phone is not allowed to act, whatever its record said',
      () async {
        final phone = await registry.register('My phone');
        await registry.setMayAct(phone.deviceId, true);

        await registry.revoke(phone.deviceId);

        expect(await registry.load(), isEmpty);
        expect(await registry.authenticate(phone.token), isNull);
      },
    );
  });
}
