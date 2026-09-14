/// The four labels every key on the phone link is bound to.
///
/// The desktop listens on plain `ws://` for a phone on the same network, and
/// on the relay path a server nobody here controls forwards the bytes. There
/// is no transport encryption underneath on either path — this channel *is*
/// the confidentiality — so every derived key has to be bound to which
/// protocol produced it. Otherwise a transcript captured from one deployment
/// replays into another that happens to share a key.
///
/// These live in a value rather than as four top-level constants for one
/// reason: `test/pairing/e2ee_vectors_test.dart` pins a *foreign*
/// implementation's labels and proves this codec reproduces its published
/// numbers byte for byte. That cross-check is the only evidence the encoding
/// is right, and it needs the labels to be an argument.
library;

/// Labels for one deployment of the v2 phone-link channel.
class E2eeSuite {
  const E2eeSuite({
    required this.protocol,
    required this.transcriptDomain,
    required this.saltLabel,
    required this.sessionLabel,
  });

  /// Grid's own labels — the only suite production ever uses.
  static const grid = E2eeSuite(
    protocol: 'grid-mobile-e2ee',
    transcriptDomain: 'grid-mobile-e2ee/v2/transcript',
    saltLabel: 'grid-mobile-e2ee/v2/salt',
    sessionLabel: 'grid-mobile-e2ee/v2/session',
  );

  /// Value of `context.protocol` in both handshake messages.
  final String protocol;

  /// First field of the handshake transcript.
  final String transcriptDomain;

  /// Prefix of the HKDF salt input, before [labelTerminator].
  final String saltLabel;

  /// Prefix of the HKDF info input, before [labelTerminator].
  final String sessionLabel;

  /// The byte that closes a label where more bytes follow it in a hash input.
  ///
  /// Kept as a byte rather than inside the label strings so nothing in this
  /// file depends on an invisible character surviving a copy-paste. Its job is
  /// to stop a label running into what follows: without it,
  /// `sha256("...salt" + clientNonce)` and `sha256("...sal" + "t" + nonce)`
  /// are the same input, so two different handshakes would share a salt.
  static const labelTerminator = 0;

  @override
  bool operator ==(Object other) =>
      other is E2eeSuite &&
      other.protocol == protocol &&
      other.transcriptDomain == transcriptDomain &&
      other.saltLabel == saltLabel &&
      other.sessionLabel == sessionLabel;

  @override
  int get hashCode =>
      Object.hash(protocol, transcriptDomain, saltLabel, sessionLabel);
}
