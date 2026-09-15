/// The vocabulary of the phone link's handshake: the enums that have a byte or
/// a word on the wire, and the context both peers must agree on.
///
/// Everything here is strict on purpose. A field this side ignores is a field
/// the other side may still be hashing into the transcript, and the first
/// symptom of that disagreement is a session that dies at frame one with a
/// decrypt failure. So parsing rejects an unknown key rather than skipping it.
library;

import 'e2ee_suite.dart';

/// Version of the handshake messages and of the frame layout.
const kE2eeVersion = 2;

/// The one framing this build speaks. Sent as a list of what the phone can do
/// and echoed back as the single value the desktop picked, so a future v3 is
/// negotiable and the choice is inside the signed transcript.
const kE2eeFraming = 2;

/// Length of a handshake nonce, a public key, and a derived key.
const kE2eeKeyLength = 32;

/// The phone always opens the channel; the desktop always answers.
const kE2eeInitiator = 'mobile';

/// See [kE2eeInitiator].
const kE2eeResponder = 'desktop';

/// Which path the socket under this channel took.
///
/// It is part of the transcript, so a handshake captured on the relay can
/// never be replayed onto a LAN socket: the two derive different keys.
enum E2eeTransport {
  direct('direct'),
  relay('relay');

  const E2eeTransport(this.wireName);

  /// How the value spells itself in JSON.
  final String wireName;

  /// The transport [value] names, or null when it names none.
  static E2eeTransport? fromWire(Object? value) {
    for (final transport in values) {
      if (transport.wireName == value) return transport;
    }
    return null;
  }
}

/// Whether a frame carries UTF-8 text or opaque bytes.
///
/// Text and binary ride the same counter but differ in the sealed header, so a
/// terminal chunk can never be re-delivered as an RPC reply.
enum E2eePayloadKind {
  text('text', 0),
  binary('binary', 1);

  const E2eePayloadKind(this.wireName, this.wireByte);

  /// How the value spells itself in JSON.
  final String wireName;

  /// How the value spells itself inside a frame header and nonce.
  final int wireByte;
}

/// The kinds a peer advertises, in the order the transcript encodes them.
const kE2eePayloadKindNames = ['text', 'binary'];

/// Which peer sealed a frame.
///
/// Each direction has its own key, so a frame reflected straight back at its
/// sender does not decrypt.
enum E2eeDirection {
  mobileToDesktop(0),
  desktopToMobile(1);

  const E2eeDirection(this.wireByte);

  /// How the value spells itself inside a frame header and nonce.
  final int wireByte;

  /// The direction a peer reading frames from this one expects.
  E2eeDirection get opposite =>
      this == mobileToDesktop ? desktopToMobile : mobileToDesktop;
}

/// A relay host id: sixteen base64url characters, derived from the desktop's
/// public key rather than handed out by the relay.
final _relayHostIdPattern = RegExp(r'^[A-Za-z0-9_-]{16}$');

/// What both peers claim about the channel they are opening.
///
/// The phone sends it, the desktop echoes it back unchanged, and both hash it.
/// A relay that rewrote any of it would hand the two peers different
/// transcripts and break its own splice.
class E2eeContext {
  const E2eeContext({
    required this.protocol,
    required this.transport,
    this.relayHostId,
  });

  /// [E2eeSuite.protocol] of the deployment this channel belongs to.
  final String protocol;

  /// Which path the socket took.
  final E2eeTransport transport;

  /// Which desktop the relay was asked for, on [E2eeTransport.relay] only.
  final String? relayHostId;

  /// The context [value] describes, or null unless every field is exactly what
  /// [suite] expects — no missing key, no extra one.
  static E2eeContext? fromJson(Object? value, {required E2eeSuite suite}) {
    if (value is! Map<String, Object?>) return null;
    final transport = E2eeTransport.fromWire(value['transport']);
    if (transport == null) return null;
    final expected = {'protocol', 'initiator', 'responder', 'transport'};
    if (transport == E2eeTransport.relay) expected.add('relayHostId');
    if (!hasExactKeys(value, expected)) return null;
    if (value['protocol'] != suite.protocol) return null;
    if (value['initiator'] != kE2eeInitiator) return null;
    if (value['responder'] != kE2eeResponder) return null;
    if (transport == E2eeTransport.direct) {
      return E2eeContext(protocol: suite.protocol, transport: transport);
    }
    final relayHostId = value['relayHostId'];
    if (relayHostId is! String || !_relayHostIdPattern.hasMatch(relayHostId)) {
      return null;
    }
    return E2eeContext(
      protocol: suite.protocol,
      transport: transport,
      relayHostId: relayHostId,
    );
  }

  /// This context as the JSON both peers send.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'initiator': kE2eeInitiator,
    'responder': kE2eeResponder,
    'transport': transport.wireName,
    if (relayHostId != null) 'relayHostId': relayHostId,
  };

  @override
  bool operator ==(Object other) =>
      other is E2eeContext &&
      other.protocol == protocol &&
      other.transport == transport &&
      other.relayHostId == relayHostId;

  @override
  int get hashCode => Object.hash(protocol, transport, relayHostId);
}

/// Whether [value] carries exactly [expected] and nothing else.
bool hasExactKeys(Map<String, Object?> value, Set<String> expected) =>
    value.length == expected.length && expected.every(value.containsKey);

/// Whether [value] is exactly the capability block a phone may offer.
///
/// One accepted shape, not a superset check. The block is hashed into the
/// transcript, so "ignore what you don't know" here would let two peers agree
/// on a session while disagreeing on what was negotiated.
bool hasExactE2eeCapabilities(Object? value) {
  if (value is! Map<String, Object?>) return false;
  if (!hasExactKeys(value, {'framing', 'payloadKinds'})) return false;
  final framing = value['framing'];
  if (framing is! List || framing.length != 1) return false;
  if (framing.first != kE2eeFraming) return false;
  return hasExactE2eePayloadKinds(value['payloadKinds']);
}

/// Whether [value] is exactly the selection a desktop may answer with.
bool hasExactE2eeSelection(Object? value) {
  if (value is! Map<String, Object?>) return false;
  if (!hasExactKeys(value, {'framing', 'payloadKinds'})) return false;
  if (value['framing'] != kE2eeFraming) return false;
  return hasExactE2eePayloadKinds(value['payloadKinds']);
}

/// Whether [value] is [kE2eePayloadKindNames], in order.
bool hasExactE2eePayloadKinds(Object? value) {
  if (value is! List || value.length != kE2eePayloadKindNames.length) {
    return false;
  }
  for (var i = 0; i < value.length; i++) {
    if (value[i] != kE2eePayloadKindNames[i]) return false;
  }
  return true;
}
