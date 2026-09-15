import 'package:flutter_test/flutter_test.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// The desktop's key is the one the pairing code pins, so it has to survive a
/// restart byte for byte; the phone's is thrown away with the socket.
void main() {
  test('both peers reach the same shared secret from opposite halves, which '
      'is the only thing the whole channel rests on', () async {
    final desktop = await E2eeKeyPair.generate();
    final phone = await E2eeKeyPair.generate();

    expect(
      await desktop.sharedSecretWith(phone.publicKey),
      await phone.sharedSecretWith(desktop.publicKey),
    );
  });

  test('two phones do not reach the same secret with one desktop', () async {
    final desktop = await E2eeKeyPair.generate();
    final first = await E2eeKeyPair.generate();
    final second = await E2eeKeyPair.generate();

    expect(
      await desktop.sharedSecretWith(first.publicKey),
      isNot(await desktop.sharedSecretWith(second.publicKey)),
    );
  });

  test('a stored private key restores the same public key, so reloading the '
      'desktop key does not un-pair every phone that scanned it', () async {
    final original = await E2eeKeyPair.generate();
    final restored = await E2eeKeyPair.fromPrivateKey(original.privateKey);

    expect(restored.publicKey, original.publicKey);
  });

  test('a key of the wrong length is refused rather than padded', () async {
    expect(
      () => E2eeKeyPair.fromPrivateKey(List.filled(31, 0)),
      throwsArgumentError,
    );
    final pair = await E2eeKeyPair.generate();
    expect(
      () => pair.sharedSecretWith(List.filled(33, 0)),
      throwsArgumentError,
    );
  });
}
