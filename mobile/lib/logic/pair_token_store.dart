/// Where this phone keeps the code for the computer it belongs to.
///
/// The code is a bearer credential for somebody's machine, so it goes in the
/// Keychain and nowhere else. `first_unlock_this_device` means it is unreadable
/// until the phone has been unlocked once since boot, and it never leaves this
/// device — not to an iCloud backup, not to a restored handset.
///
/// The computer's *name* is kept beside it, and that is the only other thing
/// stored. Everything else — where the computer is, what key it holds — is read
/// from the locator on every connection, because all of it changes and none of
/// it is worth being wrong about. The name is here so the screen can say which
/// computer it is reaching while it is still reaching it.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// The computer this phone belongs to.
typedef PairedComputer = ({PairToken token, String hostName});

/// Reads and writes the one stored code.
class PairTokenStore {
  const PairTokenStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  }) : _storage = storage;

  static const _key = 'grid.pairing.token';
  static const _version = 1;

  final FlutterSecureStorage _storage;

  /// The computer this phone holds a code for, or null when it holds none —
  /// including when the Keychain entry is unreadable, because a phone that
  /// cannot read its code is, for every purpose here, not paired.
  Future<PairedComputer?> read() async {
    final String? stored;
    try {
      stored = await _storage.read(key: _key);
    } on Object {
      return null;
    }
    if (stored == null) return null;
    final Object? value;
    try {
      value = jsonDecode(stored);
    } on FormatException {
      return null;
    }
    if (value is! Map<String, Object?> || value['v'] != _version) return null;
    final token = value['token'];
    if (token is! String) return null;
    final parsed = PairToken.tryParse(token);
    if (parsed == null) return null;
    final hostName = value['hostName'];
    return (token: parsed, hostName: hostName is String ? hostName : '');
  }

  /// Keeps [token] for next launch, under [hostName].
  Future<void> write({required PairToken token, String hostName = ''}) =>
      _storage.write(
        key: _key,
        value: jsonEncode({
          'v': _version,
          'token': token.normalized,
          'hostName': hostName,
        }),
      );

  /// Forgets the computer. It still lists this phone until somebody revokes it
  /// there — this only stops *this* phone using the code.
  Future<void> clear() => _storage.delete(key: _key);
}
