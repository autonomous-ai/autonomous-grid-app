/// The two messages that open the phone link, and the pair of them once they
/// are known to answer each other.
///
/// The phone sends [E2eeHello] in the clear, the desktop answers [E2eeReady]
/// in the clear, and from that point everything is sealed. Neither message
/// carries a secret: what makes the exchange safe is that the phone already
/// pinned the desktop's public key when it scanned the pairing code, so an
/// attacker who rewrites `desktopPublicKeyB64` produces a key the phone will
/// not accept.
///
/// What the messages *do* carry is the whole input to the key schedule, which
/// is why parsing here refuses anything it does not recognise. See
/// [E2eeHandshake.validate].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'e2ee_bytes.dart';
import 'e2ee_suite.dart';
import 'e2ee_wire.dart';

/// The phone's opening message.
class E2eeHello {
  const E2eeHello({
    required this.clientPublicKey,
    required this.clientNonce,
    required this.context,
  });

  /// The phone's ephemeral X25519 public key, fresh for this socket.
  final Uint8List clientPublicKey;

  /// 32 random bytes the phone contributes to the HKDF salt.
  final Uint8List clientNonce;

  /// What both peers claim about this channel.
  final E2eeContext context;

  /// The hello [value] describes, or null when it is not exactly one.
  static E2eeHello? fromJson(
    Object? value, {
    E2eeSuite suite = E2eeSuite.grid,
  }) {
    if (value is! Map<String, Object?>) return null;
    const keys = {
      'type',
      'v',
      'clientPublicKeyB64',
      'clientNonceB64',
      'capabilities',
      'context',
    };
    if (!hasExactKeys(value, keys)) return null;
    if (value['type'] != 'e2ee_hello') return null;
    if (value['v'] != kE2eeVersion) return null;
    if (!hasExactE2eeCapabilities(value['capabilities'])) return null;
    final context = E2eeContext.fromJson(value['context'], suite: suite);
    final publicKey = _key(value['clientPublicKeyB64']);
    final nonce = _key(value['clientNonceB64']);
    if (context == null || publicKey == null || nonce == null) return null;
    return E2eeHello(
      clientPublicKey: publicKey,
      clientNonce: nonce,
      context: context,
    );
  }

  /// This message as the JSON the phone sends.
  Map<String, Object?> toJson() => {
    'type': 'e2ee_hello',
    'v': kE2eeVersion,
    'clientPublicKeyB64': base64.encode(clientPublicKey),
    'clientNonceB64': base64.encode(clientNonce),
    'capabilities': {
      'framing': [kE2eeFraming],
      'payloadKinds': kE2eePayloadKindNames,
    },
    'context': context.toJson(),
  };
}

/// The desktop's answer.
class E2eeReady {
  const E2eeReady({
    required this.desktopPublicKey,
    required this.clientNonce,
    required this.desktopNonce,
    required this.context,
  });

  /// The desktop's long-lived X25519 public key — the one the pairing code
  /// pinned. It is echoed rather than introduced: a phone that gets a
  /// different key here is talking to something that is not its desktop.
  final Uint8List desktopPublicKey;

  /// The phone's nonce, echoed back so it is inside the desktop's half of the
  /// transcript too.
  final Uint8List clientNonce;

  /// 32 random bytes the desktop contributes to the HKDF salt.
  final Uint8List desktopNonce;

  /// The context from the hello, unchanged.
  final E2eeContext context;

  /// The answer [value] describes, or null when it is not exactly one.
  static E2eeReady? fromJson(
    Object? value, {
    E2eeSuite suite = E2eeSuite.grid,
  }) {
    if (value is! Map<String, Object?>) return null;
    const keys = {
      'type',
      'v',
      'desktopPublicKeyB64',
      'clientNonceB64',
      'desktopNonceB64',
      'selection',
      'context',
    };
    if (!hasExactKeys(value, keys)) return null;
    if (value['type'] != 'e2ee_ready') return null;
    if (value['v'] != kE2eeVersion) return null;
    if (!hasExactE2eeSelection(value['selection'])) return null;
    final context = E2eeContext.fromJson(value['context'], suite: suite);
    final publicKey = _key(value['desktopPublicKeyB64']);
    final clientNonce = _key(value['clientNonceB64']);
    final desktopNonce = _key(value['desktopNonceB64']);
    if (context == null ||
        publicKey == null ||
        clientNonce == null ||
        desktopNonce == null) {
      return null;
    }
    return E2eeReady(
      desktopPublicKey: publicKey,
      clientNonce: clientNonce,
      desktopNonce: desktopNonce,
      context: context,
    );
  }

  /// This message as the JSON the desktop sends.
  Map<String, Object?> toJson() => {
    'type': 'e2ee_ready',
    'v': kE2eeVersion,
    'desktopPublicKeyB64': base64.encode(desktopPublicKey),
    'clientNonceB64': base64.encode(clientNonce),
    'desktopNonceB64': base64.encode(desktopNonce),
    'selection': {
      'framing': kE2eeFraming,
      'payloadKinds': kE2eePayloadKindNames,
    },
    'context': context.toJson(),
  };
}

/// A hello and the answer that genuinely belongs to it.
///
/// Only [validate] can build one, and every key in the session is derived from
/// this pair. That is the whole downgrade defence: the capabilities the phone
/// offered and the one the desktop chose are inside the hashed transcript, so
/// an attacker who strips a future v3 from the offer changes the key both
/// sides derive rather than silently winning a weaker channel.
class E2eeHandshake {
  const E2eeHandshake._({required this.hello, required this.ready});

  /// The phone's opening message.
  final E2eeHello hello;

  /// The desktop's answer to it.
  final E2eeReady ready;

  /// The validated pair, or null when [ready] does not answer [hello].
  static E2eeHandshake? validate({
    required E2eeHello hello,
    required E2eeReady ready,
  }) {
    if (!constantTimeEquals(ready.clientNonce, hello.clientNonce)) return null;
    if (ready.context != hello.context) return null;
    return E2eeHandshake._(hello: hello, ready: ready);
  }
}

Uint8List? _key(Object? value) =>
    value is String ? decodeCanonicalBase64(value, kE2eeKeyLength) : null;
