/// Where this phone keeps the computer it is paired with.
///
/// The pairing code is a bearer credential for somebody's machine, so it goes
/// in the Keychain and nowhere else. `first_unlock_this_device` means it is
/// unreadable until the phone has been unlocked once since boot, and it never
/// leaves this device — not to an iCloud backup, not to a restored handset.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// Reads and writes the one paired computer.
class PairedHostStore {
  const PairedHostStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  }) : _storage = storage;

  static const _key = 'grid.pairing.offer';

  final FlutterSecureStorage _storage;

  /// The computer this phone is paired with, or null when it is paired with
  /// none — including when the Keychain entry is unreadable, because a phone
  /// that cannot read its credential is, for every purpose here, unpaired.
  Future<PairingOffer?> read() async {
    final String? stored;
    try {
      stored = await _storage.read(key: _key);
    } on Object {
      return null;
    }
    return stored == null ? null : PairingOffer.parse(stored);
  }

  /// Keeps [offer] for next launch.
  Future<void> write(PairingOffer offer) =>
      _storage.write(key: _key, value: offer.toLink());

  /// Forgets the paired computer. The desktop still lists the device until
  /// somebody revokes it there — this only stops *this* phone using it.
  Future<void> clear() => _storage.delete(key: _key);
}
