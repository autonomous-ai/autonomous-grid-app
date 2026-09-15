/// The canonical byte encoding of a finished handshake.
///
/// Both peers encode the same [E2eeHandshake] and hash the result into the key
/// schedule, so every field either side sent is cryptographically bound to the
/// keys that follow. Anything a middlebox rewrites in flight changes one
/// peer's hash and the session simply never works — which is the point: a
/// silent downgrade is turned into a loud failure.
///
/// The encoding is length-prefixed and self-delimiting on purpose. Joining the
/// fields with a separator instead would let a value containing that separator
/// forge a field boundary, so two different handshakes could encode to the
/// same bytes.
///
/// ```text
/// field(name, value) = u32(len(utf8(name))) | utf8(name)
///                    | u32(len(value))      | value
/// transcript         = 24 fields, in the order below, big-endian throughout
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'e2ee_bytes.dart';
import 'e2ee_handshake.dart';
import 'e2ee_suite.dart';
import 'e2ee_wire.dart';

/// [handshake] encoded for hashing, under [suite]'s labels.
Uint8List encodeE2eeTranscript(
  E2eeHandshake handshake, {
  E2eeSuite suite = E2eeSuite.grid,
}) {
  final hello = handshake.hello;
  final ready = handshake.ready;
  return concatBytes([
    lengthPrefixedField('domain', utf8.encode(suite.transcriptDomain)),
    lengthPrefixedField('mobile-to-desktop.type', utf8.encode('e2ee_hello')),
    lengthPrefixedField('mobile-to-desktop.version', uint32Be(kE2eeVersion)),
    lengthPrefixedField(
      'mobile-to-desktop.client-public-key',
      hello.clientPublicKey,
    ),
    lengthPrefixedField('mobile-to-desktop.client-nonce', hello.clientNonce),
    lengthPrefixedField(
      'mobile-to-desktop.capabilities.framing',
      _numberList(const [kE2eeFraming]),
    ),
    lengthPrefixedField(
      'mobile-to-desktop.capabilities.payload-kinds',
      _stringList(kE2eePayloadKindNames),
    ),
    ..._contextFields('mobile-to-desktop', hello.context),
    lengthPrefixedField('desktop-to-mobile.type', utf8.encode('e2ee_ready')),
    lengthPrefixedField('desktop-to-mobile.version', uint32Be(kE2eeVersion)),
    lengthPrefixedField(
      'desktop-to-mobile.desktop-public-key',
      ready.desktopPublicKey,
    ),
    lengthPrefixedField(
      'desktop-to-mobile.client-nonce-echo',
      ready.clientNonce,
    ),
    lengthPrefixedField('desktop-to-mobile.desktop-nonce', ready.desktopNonce),
    lengthPrefixedField(
      'desktop-to-mobile.selection.framing',
      uint32Be(kE2eeFraming),
    ),
    lengthPrefixedField(
      'desktop-to-mobile.selection.payload-kinds',
      _stringList(kE2eePayloadKindNames),
    ),
    ..._contextFields('desktop-to-mobile', ready.context),
  ]);
}

List<Uint8List> _contextFields(String prefix, E2eeContext context) => [
  lengthPrefixedField(
    '$prefix.context.protocol',
    utf8.encode(context.protocol),
  ),
  lengthPrefixedField('$prefix.context.initiator', utf8.encode(kE2eeInitiator)),
  lengthPrefixedField('$prefix.context.responder', utf8.encode(kE2eeResponder)),
  lengthPrefixedField(
    '$prefix.context.transport',
    utf8.encode(context.transport.wireName),
  ),
  // Empty on the direct path rather than absent: a field that disappears would
  // make the transcript's field count depend on the transport, and a shorter
  // encoding is one more shape to reason about.
  lengthPrefixedField(
    '$prefix.context.relay-host-id',
    utf8.encode(context.relayHostId ?? ''),
  ),
];

Uint8List _numberList(List<int> values) =>
    concatBytes([uint32Be(values.length), ...values.map(uint32Be)]);

Uint8List _stringList(List<String> values) => concatBytes([
  uint32Be(values.length),
  ...values.map((value) {
    final encoded = utf8.encode(value);
    return concatBytes([uint32Be(encoded.length), encoded]);
  }),
]);
