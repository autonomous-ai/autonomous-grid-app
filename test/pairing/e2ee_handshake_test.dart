import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'e2ee_test_bytes.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// Every field of these two messages is hashed into the key schedule, so
/// parsing has to be exact rather than forgiving. A field this side skips is a
/// field the other side may still be hashing, and the only symptom is a
/// session that dies at frame one with nothing pointing at why.
void main() {
  Map<String, Object?> hello() => E2eeHello(
    clientPublicKey: repeatedBytes(1),
    clientNonce: repeatedBytes(2),
    context: _relayContext,
  ).toJson();

  Map<String, Object?> ready() => E2eeReady(
    desktopPublicKey: repeatedBytes(3),
    clientNonce: repeatedBytes(2),
    desktopNonce: repeatedBytes(4),
    context: _relayContext,
  ).toJson();

  test('a message this code wrote is a message it reads back unchanged', () {
    final parsed = E2eeHello.fromJson(jsonDecode(jsonEncode(hello())));
    expect(parsed, isNotNull);
    expect(parsed!.clientPublicKey, repeatedBytes(1));
    expect(parsed.context.relayHostId, 'AbCdEf0123_-xyZ9');

    final answer = E2eeReady.fromJson(jsonDecode(jsonEncode(ready())));
    expect(answer, isNotNull);
    expect(answer!.desktopNonce, repeatedBytes(4));
  });

  test('an extra field is refused, because the peer that added it is hashing '
      'it and this side would not be', () {
    expect(E2eeHello.fromJson({...hello(), 'extra': 1}), isNull);
    expect(E2eeReady.fromJson({...ready(), 'extra': 1}), isNull);
    final context = {..._relayContext.toJson(), 'extra': 1};
    expect(E2eeHello.fromJson({...hello(), 'context': context}), isNull);
  });

  test('a missing field is refused', () {
    final short = {...hello()}..remove('clientNonceB64');
    expect(E2eeHello.fromJson(short), isNull);
  });

  test(
    'a version this build does not speak is refused rather than guessed',
    () {
      expect(E2eeHello.fromJson({...hello(), 'v': 3}), isNull);
      expect(E2eeHello.fromJson({...hello(), 'type': 'e2ee_ready'}), isNull);
    },
  );

  test('a non-canonical base64 key is refused, because two spellings of the '
      'same 32 bytes hash to two different transcripts', () {
    final canonical = base64.encode(Uint8List(32));
    // The last character before the padding carries two spare bits. Setting
    // one leaves the same 32 bytes but a different string.
    final twisted = '${canonical.substring(0, 42)}B=';
    expect(twisted, isNot(canonical));
    expect(E2eeHello.fromJson({...hello(), 'clientNonceB64': twisted}), isNull);
  });

  test('a relay context without a host id is refused, so a relay cannot drop '
      'the field that names which desktop was asked for', () {
    final context = {..._relayContext.toJson()}..remove('relayHostId');
    expect(E2eeHello.fromJson({...hello(), 'context': context}), isNull);
  });

  test('a host id that is not sixteen base64url characters is refused', () {
    for (final bad in ['short', 'AbCdEf0123_-xyZ', 'AbCdEf0123_-xyZ9!']) {
      final context = {..._relayContext.toJson(), 'relayHostId': bad};
      expect(
        E2eeHello.fromJson({...hello(), 'context': context}),
        isNull,
        reason: bad,
      );
    }
  });

  test('a direct context carrying a host id is refused, so the relay path '
      'cannot be claimed by a socket that never took it', () {
    final context = {
      'protocol': E2eeSuite.grid.protocol,
      'initiator': 'mobile',
      'responder': 'desktop',
      'transport': 'direct',
      'relayHostId': 'AbCdEf0123_-xyZ9',
    };
    expect(E2eeHello.fromJson({...hello(), 'context': context}), isNull);
  });

  test('another deployment protocol label is refused, which is what keeps a '
      'transcript from one grid out of another', () {
    final context = {..._relayContext.toJson(), 'protocol': 'something-else'};
    expect(E2eeHello.fromJson({...hello(), 'context': context}), isNull);
  });

  group('pairing the two messages', () {
    test('an answer that echoes a different nonce is not an answer to this '
        'hello, so the pair is refused before any key is derived', () {
      final parsed = E2eeHello.fromJson(hello())!;
      final answer = E2eeReady.fromJson({
        ...ready(),
        'clientNonceB64': base64.encode(repeatedBytes(9)),
      })!;
      expect(E2eeHandshake.validate(hello: parsed, ready: answer), isNull);
    });

    test('an answer that rewrote the context is refused, because a relay that '
        'could do that could move the session onto another path', () {
      final parsed = E2eeHello.fromJson(hello())!;
      final answer = E2eeReady.fromJson({
        ...ready(),
        'context': {
          'protocol': E2eeSuite.grid.protocol,
          'initiator': 'mobile',
          'responder': 'desktop',
          'transport': 'direct',
        },
      })!;
      expect(E2eeHandshake.validate(hello: parsed, ready: answer), isNull);
    });

    test('a matching pair validates', () {
      expect(
        E2eeHandshake.validate(
          hello: E2eeHello.fromJson(hello())!,
          ready: E2eeReady.fromJson(ready())!,
        ),
        isNotNull,
      );
    });
  });
}

const _relayContext = E2eeContext(
  protocol: 'grid-mobile-e2ee',
  transport: E2eeTransport.relay,
  relayHostId: 'AbCdEf0123_-xyZ9',
);
