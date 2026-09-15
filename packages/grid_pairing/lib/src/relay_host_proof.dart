/// Proving to a relay that this machine owns the host id it is claiming —
/// without becoming the relay's signing oracle.
///
/// The id is not something a relay hands out. It is **derived from this
/// desktop's own public key**, the same key the pairing code puts in the
/// phone's hands, so claiming another machine's id means holding its private
/// key. What is left to prove is possession, and the relay proves it by
/// sealing a secret to the claimed key: only the real holder can read it back.
///
/// The half that matters on *this* side is the transcript sealed alongside it.
/// A challenge/response where only the server chooses what gets signed is a
/// signing oracle — a relay this desktop happens to reach could collect an
/// answer that is valid at a relay it is impersonating. So the transcript names
/// the origin, the id, the key and the window, and [answerRelayHostChallenge]
/// checks every field against what this machine believes before it signs
/// anything. A field that disagrees is a refusal, not a warning.
///
/// The relay's half lives in `pairing_relay/host_proof.py` in the CLI repo, and
/// `tool/pairing_relay_probe.dart` drives the two against each other.
library;

import 'dart:convert';
import 'dart:typed_data';

// Both packages export an `Hmac`; this file needs one from each side.
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'e2ee_bytes.dart';
import 'e2ee_key_schedule.dart';
import 'e2ee_keys.dart';
import 'e2ee_wire.dart';

/// Domain of the transcript both sides authenticate.
const kRelayHostProofDomain = 'grid-relay-host-proof/v1';

/// Domain the challenge itself is sealed under.
const kRelayChallengeDomain = 'grid-relay-host-challenge/v1';

/// Characters of a relay host id.
///
/// 96 bits of a SHA-256, which no number of desktops that will ever exist can
/// collide, and short enough to sit in a URL path and a QR code.
const kRelayHostIdChars = 16;

/// Nonce length of the AEAD the challenge is sealed with (RFC 8439).
const kRelayChallengeNonceLength = 12;

const _macLength = 16;
const _cipher = DartChacha20.poly1305Aead();

/// The host id [publicKey] owns.
String deriveRelayHostId(List<int> publicKey) {
  if (publicKey.length != kE2eeKeyLength) {
    throw ArgumentError('public key must be $kE2eeKeyLength bytes');
  }
  final digest = crypto.sha256.convert(publicKey).bytes;
  return base64Url
      .encode(digest)
      .replaceAll('=', '')
      .substring(0, kRelayHostIdChars);
}

/// What a relay sends. Carries nothing a wrong holder can use.
class RelayHostChallenge {
  const RelayHostChallenge({
    required this.challengeId,
    required this.relayEphemeralPublicKey,
    required this.nonce,
    required this.ciphertext,
    required this.expiresAtMs,
  });

  /// Names this challenge inside its own transcript.
  final String challengeId;

  /// Fresh per challenge, so no two are sealed to the same shared secret.
  final Uint8List relayEphemeralPublicKey;

  /// AEAD nonce.
  final Uint8List nonce;

  /// The sealed transcript and secret.
  final Uint8List ciphertext;

  /// When the relay stops accepting an answer.
  final int expiresAtMs;

  /// The challenge [value] describes, or null when it is not one.
  static RelayHostChallenge? fromJson(Object? value) {
    if (value is! Map<String, Object?> || value['type'] != 'host-challenge') {
      return null;
    }
    final challengeId = value['challengeId'];
    final expiresAt = value['expiresAt'];
    final ephemeral = _bytes(
      value['relayEphemeralPublicKeyB64'],
      kE2eeKeyLength,
    );
    final nonce = _bytes(value['nonceB64'], kRelayChallengeNonceLength);
    final ciphertext = _bytes(value['ciphertextB64'], null);
    if (challengeId is! String ||
        expiresAt is! int ||
        ephemeral == null ||
        nonce == null ||
        ciphertext == null) {
      return null;
    }
    return RelayHostChallenge(
      challengeId: challengeId,
      relayEphemeralPublicKey: ephemeral,
      nonce: nonce,
      ciphertext: ciphertext,
      expiresAtMs: expiresAt,
    );
  }
}

/// What this desktop believes, and will not sign anything that differs from.
class RelayHostProofContext {
  const RelayHostProofContext({
    required this.relayOrigin,
    required this.relayHostId,
    required this.hostPublicKey,
  });

  /// The origin this desktop dialled, spelled exactly as it dialled it. A cell
  /// that believes it is `ws://localhost` and a desktop that dialled
  /// `ws://127.0.0.1` fail every handshake, each convinced the other is broken.
  final String relayOrigin;

  /// The id this desktop is claiming.
  final String relayHostId;

  /// The key that id must derive from.
  final Uint8List hostPublicKey;
}

/// What answering a challenge came to.
sealed class RelayHostProofOutcome {
  const RelayHostProofOutcome();
}

/// The challenge was ours, and this is the answer.
final class RelayHostProofAnswered extends RelayHostProofOutcome {
  const RelayHostProofAnswered(this.proofB64);

  /// `HMAC-SHA256(secret, tag | transcript)`, base64.
  final String proofB64;
}

/// The challenge was refused, naming the failing check.
///
/// The name only, never the value it disagreed with — a reason that quoted the
/// transcript would put it into whatever log this lands in.
final class RelayHostProofRefused extends RelayHostProofOutcome {
  const RelayHostProofRefused(this.check);

  /// Which check failed.
  final String check;
}

/// The answer to [challenge], or why this desktop will not give one.
Future<RelayHostProofOutcome> answerRelayHostChallenge(
  RelayHostChallenge challenge, {
  required E2eeKeyPair hostKeyPair,
  required RelayHostProofContext context,
  required int nowMs,
  int maxWindowMs = 10000,
  int skewMs = 30000,
}) async {
  if (challenge.ciphertext.length < _macLength + 4 + kE2eeKeyLength) {
    return const RelayHostProofRefused('ciphertext-too-short');
  }
  final shared = await hostKeyPair.sharedSecretWith(
    challenge.relayEphemeralPublicKey,
  );
  final key = hkdfSha256(
    ikm: shared,
    salt: challenge.nonce,
    info: utf8.encode(kRelayChallengeDomain),
    length: kE2eeKeyLength,
  );
  final split = challenge.ciphertext.length - _macLength;
  final Uint8List plaintext;
  try {
    plaintext = Uint8List.fromList(
      _cipher.decryptSync(
        SecretBox(
          challenge.ciphertext.sublist(0, split),
          nonce: challenge.nonce,
          mac: Mac(challenge.ciphertext.sublist(split)),
        ),
        secretKey: SecretKeyData(key),
        aad: utf8.encode(kRelayChallengeDomain),
      ),
    );
  } on SecretBoxAuthenticationError {
    // The only honest reading: this was not sealed to our key.
    return const RelayHostProofRefused('challenge-undecryptable');
  }

  final view = ByteData.view(plaintext.buffer, plaintext.offsetInBytes);
  final length = view.getUint32(0, Endian.big);
  if (4 + length + kE2eeKeyLength != plaintext.length) {
    return const RelayHostProofRefused('plaintext-length-mismatch');
  }
  final transcript = plaintext.sublist(4, 4 + length);
  final secret = plaintext.sublist(4 + length);
  final fields = parseLengthPrefixedFields(transcript);
  if (fields == null) {
    return const RelayHostProofRefused('transcript-structure');
  }

  final failed = _failingChecks(
    fields,
    challenge: challenge,
    context: context,
    nowMs: nowMs,
    maxWindowMs: maxWindowMs,
    skewMs: skewMs,
  );
  if (failed.isNotEmpty) {
    return RelayHostProofRefused('transcript:${failed.join('+')}');
  }
  return RelayHostProofAnswered(
    base64.encode(
      crypto.Hmac(crypto.sha256, secret).convert(_proofInput(transcript)).bytes,
    ),
  );
}

List<int> _proofInput(List<int> transcript) => concatBytes([
  utf8.encode(kRelayHostProofDomain),
  const [0],
  utf8.encode('ack'),
  const [0],
  transcript,
]);

List<String> _failingChecks(
  Map<String, Uint8List> fields, {
  required RelayHostChallenge challenge,
  required RelayHostProofContext context,
  required int nowMs,
  required int maxWindowMs,
  required int skewMs,
}) {
  if (fields.length != 10) return ['field-count'];
  final issuedAt = _readUint64(fields['issuedAt']);
  final expiresAt = _readUint64(fields['expiresAt']);
  if (issuedAt == null || expiresAt == null) return ['timestamps'];
  final checks = <String, bool>{
    'protocol': _equals(fields['protocol'], utf8.encode(kRelayHostProofDomain)),
    'version': _equals(fields['version'], uint32Be(1)),
    'relayOrigin': _equals(
      fields['relayOrigin'],
      utf8.encode(context.relayOrigin),
    ),
    'relayEphemeralPublicKey': _equals(
      fields['relayEphemeralPublicKey'],
      challenge.relayEphemeralPublicKey,
    ),
    'challengeNonce': _equals(fields['challengeNonce'], challenge.nonce),
    'challengeId': _equals(
      fields['challengeId'],
      utf8.encode(challenge.challengeId),
    ),
    'relayHostId': _equals(
      fields['relayHostId'],
      utf8.encode(context.relayHostId),
    ),
    'hostPublicKey': _equals(fields['hostPublicKey'], context.hostPublicKey),
    // Our own id must be the one our key owns, or this desktop is
    // misconfigured and would be proving possession of an id it cannot hold.
    'relayHostId-derives-from-key':
        context.relayHostId == deriveRelayHostId(context.hostPublicKey),
    'expiry-consistent': expiresAt == challenge.expiresAtMs,
    'issued-before-expiry': issuedAt <= expiresAt,
    'window': expiresAt - issuedAt <= maxWindowMs,
    'not-expired': nowMs - skewMs <= expiresAt,
    'not-future': issuedAt - skewMs <= nowMs,
  };
  return [
    for (final entry in checks.entries)
      if (!entry.value) entry.key,
  ];
}

bool _equals(Uint8List? actual, List<int> expected) =>
    actual != null && constantTimeEquals(actual, expected);

int? _readUint64(Uint8List? value) {
  if (value == null || value.length != 8) return null;
  var result = 0;
  for (final byte in value) {
    result = (result << 8) | byte;
  }
  return result;
}

Uint8List? _bytes(Object? value, int? length) {
  if (value is! String) return null;
  final Uint8List decoded;
  try {
    decoded = base64.decode(value);
  } on FormatException {
    return null;
  }
  if (length != null && decoded.length != length) return null;
  return decoded;
}
