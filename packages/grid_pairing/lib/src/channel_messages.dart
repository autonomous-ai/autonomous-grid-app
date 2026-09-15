/// What the two peers say to each other once the channel is sealed.
///
/// The handshake proved the *desktop's* identity to the phone: the phone had
/// already pinned that public key from the pairing code, so a relay in the
/// middle cannot stand in for it. Nothing in the handshake proves the reverse
/// — anyone who can reach the relay can complete one. [E2eeAuth] is the other
/// half: a per-device token the desktop issued, which it can revoke for one
/// phone without touching the rest.
///
/// It carries the transcript hash back as well. That costs nothing and closes
/// the case where the two sides somehow derived different keys but a bug let
/// traffic flow anyway: the desktop compares, and refuses.
library;

/// The phone's first sealed message.
class E2eeAuth {
  const E2eeAuth({required this.deviceToken, required this.transcriptHashB64});

  /// This phone's credential on this desktop.
  final String deviceToken;

  /// Base64 of the SHA-256 both sides derived from the handshake.
  final String transcriptHashB64;

  /// This message as JSON, for sealing.
  Map<String, Object?> toJson() => {
    'type': 'e2ee_auth',
    'deviceToken': deviceToken,
    'transcriptHashB64': transcriptHashB64,
  };

  /// The auth [value] describes, or null when it is not exactly one.
  static E2eeAuth? fromJson(Object? value) {
    if (value is! Map<String, Object?> || value['type'] != 'e2ee_auth') {
      return null;
    }
    // Exact shape. A field this side ignores is a field a peer might be
    // relying on, and the failure would land somewhere much later.
    if (value.length != 3) return null;
    final token = value['deviceToken'];
    final hash = value['transcriptHashB64'];
    if (token is! String || token.isEmpty || hash is! String) return null;
    return E2eeAuth(deviceToken: token, transcriptHashB64: hash);
  }
}

/// The desktop's answer once the token checks out.
class E2eeAuthenticated {
  const E2eeAuthenticated({required this.hostName});

  /// What the phone should call this computer.
  final String hostName;

  /// This message as JSON, for sealing.
  Map<String, Object?> toJson() => {
    'type': 'e2ee_authenticated',
    'hostName': hostName,
  };

  /// The acknowledgement [value] describes, or null when it is not one.
  static E2eeAuthenticated? fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value['type'] != 'e2ee_authenticated') {
      return null;
    }
    final hostName = value['hostName'];
    return hostName is String ? E2eeAuthenticated(hostName: hostName) : null;
  }
}
