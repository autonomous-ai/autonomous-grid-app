/// The pairing code: everything a phone needs to reach one desktop, and
/// nothing it could use to reach anyone else's.
///
/// The whole offer travels as one base64url blob inside a `grid://pair` link,
/// so it fits a QR code and survives being pasted into a text field. Query
/// parameter rather than fragment: Android camera intents and most link
/// handlers preserve a query and drop a fragment.
///
/// **The public key is the point.** A phone that has read this offer has
/// *pinned* the desktop's key before it opens a socket, so the relay in the
/// middle — which can see this traffic and rewrite it — cannot substitute its
/// own. That is what lets the rest of the system treat the relay as untrusted.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'e2ee_bytes.dart';
import 'e2ee_wire.dart';

/// Bumped when the offer's shape changes in a way an older phone cannot read.
const kPairingOfferVersion = 1;

/// The scheme and host a pairing link uses.
const kPairingLinkPrefix = 'grid://pair';

/// Longest link this code will even try to parse, so a pasted novel is refused
/// before it is decoded rather than after.
const kPairingLinkMaxCharacters = 4096;

/// Where the phone dials, and with what, to reach one desktop through a relay.
class PairingRelayEndpoint {
  const PairingRelayEndpoint({
    required this.cellUrl,
    required this.relayHostId,
    required this.inviteToken,
    required this.inviteExpiresAtMs,
  });

  /// Origin of the relay cell, e.g. `ws://127.0.0.1:8787`.
  ///
  /// A local cell speaks `ws://`; anything reachable off this machine must be
  /// `wss://`, because the invite token below is authority and it is in the
  /// clear on the wire. The end-to-end layer protects the conversation, never
  /// the credential that starts it.
  final String cellUrl;

  /// Which desktop to ask the relay for. Derived from the desktop's key.
  final String relayHostId;

  /// One connection's worth of authority, and it expires.
  final String inviteToken;

  /// When the relay stops honouring [inviteToken].
  final int inviteExpiresAtMs;

  /// This endpoint as the JSON inside a pairing code.
  Map<String, Object?> toJson() => {
    'cellUrl': cellUrl,
    'relayHostId': relayHostId,
    'inviteToken': inviteToken,
    'inviteExpiresAt': inviteExpiresAtMs,
  };

  /// The endpoint [value] describes, or null when it is not one.
  static PairingRelayEndpoint? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final cellUrl = value['cellUrl'];
    final relayHostId = value['relayHostId'];
    final inviteToken = value['inviteToken'];
    final expiresAt = value['inviteExpiresAt'];
    if (cellUrl is! String ||
        relayHostId is! String ||
        inviteToken is! String ||
        expiresAt is! int ||
        !_isWebSocketOrigin(cellUrl) ||
        !RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(relayHostId) ||
        inviteToken.isEmpty) {
      return null;
    }
    return PairingRelayEndpoint(
      cellUrl: cellUrl,
      relayHostId: relayHostId,
      inviteToken: inviteToken,
      inviteExpiresAtMs: expiresAt,
    );
  }
}

/// A complete pairing code.
class PairingOffer {
  const PairingOffer({
    required this.deviceToken,
    required this.hostPublicKey,
    required this.hostName,
    required this.relay,
  });

  /// This phone's own credential on this desktop. Revocable on its own, so
  /// losing one device does not expose the others.
  final String deviceToken;

  /// The desktop's long-lived X25519 public key, pinned by whoever scans this.
  final Uint8List hostPublicKey;

  /// What to call this computer on the phone's screen.
  final String hostName;

  /// How to reach it.
  final PairingRelayEndpoint relay;

  /// The `grid://pair?code=...` link that carries this offer.
  String toLink() {
    final json = jsonEncode({
      'v': kPairingOfferVersion,
      'deviceToken': deviceToken,
      'hostPublicKeyB64': base64.encode(hostPublicKey),
      'hostName': hostName,
      'relay': relay.toJson(),
    });
    final code = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    return '$kPairingLinkPrefix?code=$code';
  }

  /// The offer [link] carries, or null when it is not a pairing link this
  /// build understands.
  ///
  /// Accepts the bare code as well as the full link, because what a person
  /// actually copies off a screen is one or the other and they cannot be
  /// expected to know which.
  static PairingOffer? parse(String link) {
    final trimmed = link.trim();
    if (trimmed.isEmpty || trimmed.length > kPairingLinkMaxCharacters) {
      return null;
    }
    final code = trimmed.toLowerCase().startsWith('grid://')
        ? _codeFromLink(trimmed)
        : trimmed;
    if (code == null) return null;
    final Object? value;
    try {
      value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(code))),
      );
    } on FormatException {
      return null;
    }
    return _fromJson(value);
  }

  static PairingOffer? _fromJson(Object? value) {
    if (value is! Map<String, Object?> || value['v'] != kPairingOfferVersion) {
      return null;
    }
    final deviceToken = value['deviceToken'];
    final hostName = value['hostName'];
    final publicKey = value['hostPublicKeyB64'] is String
        ? decodeCanonicalBase64(
            value['hostPublicKeyB64']! as String,
            kE2eeKeyLength,
          )
        : null;
    final relay = PairingRelayEndpoint.fromJson(value['relay']);
    if (deviceToken is! String ||
        deviceToken.isEmpty ||
        hostName is! String ||
        publicKey == null ||
        relay == null) {
      return null;
    }
    return PairingOffer(
      deviceToken: deviceToken,
      hostPublicKey: publicKey,
      hostName: hostName,
      relay: relay,
    );
  }

  static String? _codeFromLink(String link) {
    final Uri parsed;
    try {
      parsed = Uri.parse(link);
    } on FormatException {
      return null;
    }
    // Only the pairing host may carry auth material: `grid://pairing?...` and
    // `grid://open?code=...` are different routes and must not be read as this.
    if (parsed.scheme != 'grid' || parsed.host != 'pair') return null;
    if (parsed.path.isNotEmpty && parsed.path != '/') return null;
    final code = parsed.queryParameters['code'];
    return code != null && code.isNotEmpty ? code : null;
  }
}

bool _isWebSocketOrigin(String value) {
  final parsed = Uri.tryParse(value);
  if (parsed == null) return false;
  if (parsed.scheme != 'ws' && parsed.scheme != 'wss') return false;
  return parsed.host.isNotEmpty &&
      (parsed.path.isEmpty || parsed.path == '/') &&
      !parsed.hasQuery &&
      !parsed.hasFragment;
}
