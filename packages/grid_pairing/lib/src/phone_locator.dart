/// Where a computer can be reached right now, and the sealed record that says
/// so.
///
/// A phone and a computer cannot dial each other: both sit behind something
/// that only lets connections out. The computer therefore puts a tunnel in
/// front of itself — and a quick tunnel's address is new every time it opens,
/// which is exactly the thing a person must never be asked to carry. So the
/// address is published, encrypted, under a name derived from the phone's token
/// (`pair_token.dart`), and the phone reads it there every time it connects.
///
/// **What the locator holds is one address and nothing else.** Not a chat, not a
/// transcript, not a file. That boundary is why this is affordable on a free
/// tier at all, and it is a rule rather than a habit: the phone's own RPC polls
/// while a chat is open, and one open chat would spend a day's read quota in an
/// afternoon.
///
/// **A poisoned record is a phone that cannot connect, never a phone that
/// connects to the wrong computer.** The record is sealed with a key only the
/// two devices hold, so nobody else can write one that opens; and it carries
/// [LocatorRecord.hostPublicKey], which the phone then requires the computer on
/// the other end to prove it holds. The worst an attacker with the database can
/// do is delete a row, which reads as a computer that is asleep.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'e2ee_bytes.dart';
import 'e2ee_wire.dart';

/// Bumped when the sealed record's shape changes in a way an older phone cannot
/// read. A phone that finds a version it does not know says so and asks for a
/// newer Grid, rather than guessing at the fields it recognises.
const int kLocatorRecordVersion = 1;

/// Nonce bytes in a sealed record, and the same AEAD the channel itself uses —
/// XChaCha20-Poly1305, whose 24-byte nonce is large enough to be picked at
/// random for every write with nothing to track and nothing to collide.
const int kLocatorNonceLength = 24;

/// Tag bytes at the end of a sealed record.
const int kLocatorMacLength = 16;

/// The most base64 a record may become.
///
/// Firestore's own ceiling is 1 MiB per document and the rules refuse anything
/// near it; a record is a few hundred bytes, so this only ever catches a
/// mistake. Checked before the write so the failure names the record rather
/// than arriving as a 400 from Google.
const int kLocatorMaxBlobCharacters = 8192;

const _cipher = DartXchacha20.poly1305Aead();

/// Bound into every sealed record, so a blob lifted from anywhere else — a
/// different product on the same Firestore project, an older shape of this one —
/// fails to open instead of being read as an address.
const String _locatorAad = 'grid.phone.locator/v1';

/// One computer's address, as the phone holding the token reads it.
class LocatorRecord {
  const LocatorRecord({
    required this.cellUrl,
    required this.relayHostId,
    required this.hostPublicKey,
    required this.hostName,
    required this.publishedAtMs,
  });

  /// Where to dial, e.g. `wss://phase-fridge-spa.trycloudflare.com`.
  ///
  /// Always `wss://` in production. The channel inside is encrypted either way,
  /// but a `ws://` address means a tunnel that is not doing TLS, and every
  /// intermediary on the path then sees which computer a phone is asking for.
  final String cellUrl;

  /// Which computer to ask for, derived from its long-lived key. Part of the
  /// path a phone dials, so the computer can refuse a stale record loudly
  /// instead of serving a phone that meant a different machine.
  final String relayHostId;

  /// The computer's long-lived public key, which the phone then requires the
  /// other end of the socket to hold. This is the pin, and it is the reason a
  /// tunnel operator cannot stand in the middle.
  final Uint8List hostPublicKey;

  /// What to call this computer on the phone's screen.
  final String hostName;

  /// When the computer wrote this. Shown as "last seen" when a connection
  /// fails: an address published four days ago is a computer that has not been
  /// opened since, which is a different problem from one that is refusing.
  final int publishedAtMs;

  /// This record as the JSON that gets sealed.
  Map<String, Object?> toJson() => {
    'v': kLocatorRecordVersion,
    'cellUrl': cellUrl,
    'relayHostId': relayHostId,
    'hostPublicKeyB64': base64.encode(hostPublicKey),
    'hostName': hostName,
    'at': publishedAtMs,
  };

  /// The record [value] describes, or null when it is not one this build can
  /// use.
  ///
  /// Every field is checked, including the ones that "cannot" be wrong: this
  /// JSON arrives from a database anybody can write to, and the only reason a
  /// forged row is harmless is that it never gets this far — but a row written
  /// by a *newer* Grid does, and it must fail as a version rather than as a
  /// crash in the dialler.
  static LocatorRecord? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    if (value['v'] != kLocatorRecordVersion) return null;
    final cellUrl = value['cellUrl'];
    final relayHostId = value['relayHostId'];
    final hostName = value['hostName'];
    final publishedAt = value['at'];
    final publicKey = value['hostPublicKeyB64'] is String
        ? decodeCanonicalBase64(
            value['hostPublicKeyB64']! as String,
            kE2eeKeyLength,
          )
        : null;
    if (cellUrl is! String ||
        !isWebSocketOrigin(cellUrl) ||
        relayHostId is! String ||
        !_hostId.hasMatch(relayHostId) ||
        publicKey == null ||
        hostName is! String ||
        publishedAt is! int) {
      return null;
    }
    return LocatorRecord(
      cellUrl: cellUrl,
      relayHostId: relayHostId,
      hostPublicKey: publicKey,
      hostName: hostName,
      publishedAtMs: publishedAt,
    );
  }

  /// Value equality, so a controller can tell "the tunnel moved" from "the
  /// tunnel is where it was" and skip the write. Without it every republish
  /// spends a write on a project whose whole daily budget is shared.
  @override
  bool operator ==(Object other) =>
      other is LocatorRecord &&
      other.cellUrl == cellUrl &&
      other.relayHostId == relayHostId &&
      other.hostName == hostName &&
      other.publishedAtMs == publishedAtMs &&
      constantTimeEquals(other.hostPublicKey, hostPublicKey);

  @override
  int get hashCode =>
      Object.hash(cellUrl, relayHostId, hostName, publishedAtMs);
}

/// [record] sealed with [key], as the base64 string that goes in the document.
///
/// [random] is for tests only; production takes [Random.secure]. A repeated
/// nonce under one key is the one way to break this construction, and 24 random
/// bytes never repeat in the handful of writes a computer ever makes.
String sealLocatorRecord(
  LocatorRecord record,
  List<int> key, {
  Random? random,
}) {
  final rng = random ?? Random.secure();
  final nonce = Uint8List.fromList(
    List.generate(kLocatorNonceLength, (_) => rng.nextInt(256)),
  );
  final sealed = _cipher.encryptSync(
    utf8.encode(jsonEncode(record.toJson())),
    secretKey: SecretKeyData(key),
    nonce: nonce,
    aad: utf8.encode(_locatorAad),
  );
  return base64.encode(
    concatBytes([nonce, sealed.cipherText, sealed.mac.bytes]),
  );
}

/// The record [blob] holds, or null when this key does not open it.
///
/// One null for every reason, and the caller says "that token does not match
/// this record" rather than guessing which part was wrong: a wrong token, a
/// tampered row and a truncated write are the same answer to the person
/// holding the phone, and telling them apart only helps somebody who should
/// not have the row.
LocatorRecord? openLocatorRecord(String blob, List<int> key) {
  if (blob.length > kLocatorMaxBlobCharacters) return null;
  final Uint8List raw;
  try {
    raw = base64.decode(blob);
  } on FormatException {
    return null;
  }
  if (raw.length <= kLocatorNonceLength + kLocatorMacLength) return null;
  final body = raw.sublist(kLocatorNonceLength, raw.length - kLocatorMacLength);
  try {
    final plaintext = _cipher.decryptSync(
      SecretBox(
        body,
        nonce: raw.sublist(0, kLocatorNonceLength),
        mac: Mac(raw.sublist(raw.length - kLocatorMacLength)),
      ),
      secretKey: SecretKeyData(key),
      aad: utf8.encode(_locatorAad),
    );
    return LocatorRecord.fromJson(jsonDecode(utf8.decode(plaintext)));
  } on SecretBoxAuthenticationError {
    return null;
  } on FormatException {
    // Opened, and what was inside was not JSON. Only reachable from a record
    // sealed by something that holds the key and got it wrong, which is a bug
    // here rather than an attack.
    return null;
  }
}

/// Whether [value] is a bare websocket origin — scheme, host, optional port,
/// and nothing else.
///
/// A path, a query or a fragment here would be appended to by the dialler and
/// produce a URL nobody intended, so the shape is refused rather than repaired.
bool isWebSocketOrigin(String value) {
  final parsed = Uri.tryParse(value);
  if (parsed == null) return false;
  if (parsed.scheme != 'ws' && parsed.scheme != 'wss') return false;
  return parsed.host.isNotEmpty &&
      (parsed.path.isEmpty || parsed.path == '/') &&
      !parsed.hasQuery &&
      !parsed.hasFragment;
}

final RegExp _hostId = RegExp(r'^[A-Za-z0-9_-]{16}$');
