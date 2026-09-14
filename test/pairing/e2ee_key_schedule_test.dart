import 'package:flutter_test/flutter_test.dart';

import 'e2ee_test_bytes.dart';
import 'package:grid_app/infrastructure/pairing/e2ee_key_schedule.dart';

/// HKDF is written out in this repo rather than taken from a package, so it is
/// pinned to the RFC's own answers. A wrong HKDF is invisible: both peers
/// would still derive the *same* wrong keys and the link would work, while the
/// key separation the design pays for quietly does not exist.
void main() {
  group('HKDF-SHA256 against RFC 5869', () {
    test('case 1: the basic vector, salt and info both present', () {
      expect(
        hexOf(
          hkdfSha256(
            ikm: repeatedBytes(0x0b, 22),
            salt: hexBytes('000102030405060708090a0b0c'),
            info: hexBytes('f0f1f2f3f4f5f6f7f8f9'),
            length: 42,
          ),
        ),
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('case 2: inputs longer than the hash, and output spanning blocks', () {
      expect(
        hexOf(
          hkdfSha256(
            ikm: countingBytes(0x00, 80),
            salt: countingBytes(0x60, 80),
            info: countingBytes(0xb0, 80),
            length: 82,
          ),
        ),
        'b11e398dc80327a1c8e7f78c596a4934'
        '4f012eda2d4efad8a050cc4c19afa97c'
        '59045a99cac7827271cb41c65e590e09'
        'da3275600c2f09b8367793a9aca3db71'
        'cc30c58179ec3e87c14c01d5c1f3434f'
        '1d87',
      );
    });

    test('case 3: an empty salt still extracts, which the phone never uses '
        'but a future caller might reach for', () {
      expect(
        hexOf(
          hkdfSha256(
            ikm: repeatedBytes(0x0b, 22),
            salt: const [],
            info: const [],
            length: 42,
          ),
        ),
        '8da4e775a563c18f715f802a063c5a31'
        'b8a11f5c5ee1879ec3454e5f3c738d2d'
        '9d201395faa4b61a96c8',
      );
    });
  });

  test('a length outside what HKDF-SHA256 can produce is refused rather than '
      'quietly truncated', () {
    expect(
      () => hkdfSha256(ikm: [1], salt: [], info: [], length: 0),
      throwsArgumentError,
    );
    expect(
      () => hkdfSha256(ikm: [1], salt: [], info: [], length: 255 * 32 + 1),
      throwsArgumentError,
    );
  });

  test('a shared secret of the wrong length is refused at the door, because a '
      'short one would still derive usable-looking keys', () {
    expect(
      () => deriveE2eeKeySchedule(
        sharedSecret: repeatedBytes(1, 31),
        transcript: const [],
        clientNonce: repeatedBytes(2, 32),
        desktopNonce: repeatedBytes(3, 32),
      ),
      throwsArgumentError,
    );
  });
}
