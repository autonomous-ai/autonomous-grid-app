import 'package:flutter_test/flutter_test.dart';

import 'package:grid_app/features/connectors/logic/dcr_oauth_client.dart';

/// Pins the hand-rolled SHA-256 behind PKCE to a published vector.
///
/// `dcr_oauth_client.dart` implements SHA-256 itself rather than adding
/// `package:crypto` for one hash. That trade is only defensible while the
/// implementation is pinned: a subtly wrong hash would produce a challenge the
/// authorization server rejects, and the failure would surface as "sign-in
/// didn't work" with nothing pointing at the maths.
void main() {
  group('PKCE S256', () {
    test('matches the RFC 7636 appendix-B vector', () {
      // RFC 7636 §B: this exact verifier must produce this exact challenge.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expected = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

      expect(challengeFor(verifier), expected);
    });

    test('a generated pair verifies against its own challenge', () {
      final pair = PkcePair.create();

      expect(challengeFor(pair.verifier), pair.challenge);
      // RFC 7636 §4.1: 43 characters is the minimum length, and base64url of 32
      // bytes lands exactly there.
      expect(pair.verifier.length, 43);
      // Unpadded base64url — a '=' in a query parameter has to be escaped and
      // some servers reject it outright.
      expect(pair.verifier, isNot(contains('=')));
      expect(pair.challenge, isNot(contains('=')));
    });

    test('two pairs differ', () {
      // Random.secure() returning a constant would make every verifier
      // guessable, which for a public client is the whole protection.
      expect(PkcePair.create().verifier, isNot(PkcePair.create().verifier));
    });

    test('state values are unpadded and unique', () {
      final a = randomStateValue();
      final b = randomStateValue();

      expect(a, isNot(b));
      expect(a, isNot(contains('=')));
      expect(a.length, greaterThanOrEqualTo(32));
    });
  });
}
