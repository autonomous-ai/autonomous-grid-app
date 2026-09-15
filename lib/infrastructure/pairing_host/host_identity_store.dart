/// This computer's long-lived identity on the phone link.
///
/// One keypair, generated once and kept. Its public half goes into every
/// pairing code, so every phone that has ever paired has pinned it — which
/// makes this file the single thing whose loss un-pairs the lot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:grid_pairing/grid_pairing.dart';

import '../../core/grid_paths.dart';
import '../../core/owner_only_file.dart';

const _fileVersion = 1;

/// The identity file exists but could not be read.
///
/// Its own exception type because the only safe response is to stop. See
/// [HostIdentityStore.loadOrCreate].
class HostIdentityUnreadable implements Exception {
  const HostIdentityUnreadable(this.path, this.cause);

  /// Where the unreadable file is.
  final String path;

  /// What the read failed with.
  final Object cause;

  @override
  String toString() =>
      'Cannot read the phone-link identity at $path. Refusing to replace it: '
      'that would un-pair every phone. ($cause)';
}

/// Reads, and when there is nothing to read, creates.
class HostIdentityStore {
  const HostIdentityStore({File? file}) : _file = file;

  /// Where the identity lives. Injectable so a test can point it at a temp
  /// directory — nothing here may ever touch the real `~/.grid`.
  final File? _file;

  File get _path => _file ?? GridPaths.pairingIdentityFile;

  /// This computer's keypair.
  ///
  /// **A failed read is not an absent file.** Falling through to "generate a
  /// new one" when the read throws would silently un-pair every device — and
  /// the write would succeed, so nothing downstream would catch it. A file
  /// that is *there* and unreadable stops this method; only a missing or
  /// genuinely malformed one is replaced.
  Future<E2eeKeyPair> loadOrCreate() async {
    final file = _path;
    // `typeSync`, not `File.existsSync`: the latter answers "is there a *file*
    // here", so a directory — or anything else — sitting at the path reads as
    // absent, and the next step would be to write a new identity over it. The
    // question that matters is whether *something* is there.
    if (FileSystemEntity.typeSync(file.path) != FileSystemEntityType.notFound) {
      final String raw;
      try {
        raw = await file.readAsString();
      } on FileSystemException catch (error) {
        throw HostIdentityUnreadable(file.path, error);
      }
      final restored = await _restore(raw);
      if (restored != null) return restored;
    }
    final created = await E2eeKeyPair.generate();
    await _write(file, created);
    return created;
  }

  Future<E2eeKeyPair?> _restore(String raw) async {
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (value is! Map<String, Object?> || value['v'] != _fileVersion) {
      return null;
    }
    final privateKey = value['privateKeyB64'];
    if (privateKey is! String) return null;
    final bytes = decodeCanonicalBase64(privateKey, kE2eeKeyLength);
    if (bytes == null) return null;
    return E2eeKeyPair.fromPrivateKey(bytes);
  }

  Future<void> _write(File file, E2eeKeyPair keyPair) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'v': _fileVersion,
        'privateKeyB64': base64.encode(keyPair.privateKey),
        'publicKeyB64': base64.encode(keyPair.publicKey),
        'relayHostId': deriveRelayHostId(keyPair.publicKey),
      }),
    );
    await restrictToOwner(file);
  }
}
