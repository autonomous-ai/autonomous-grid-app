import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// Locks the (deliberately counterintuitive) grid-visibility mapping so nobody
/// "fixes" it back: on the wire, `permissioned-providers` is the *public* grid
/// and `permissioned-public` is actually *private*. See [NetworkCredential.isPublic].
NetworkCredential _credOfType(String type) => NetworkCredential.fromToml({
  'network_id': 'grid-x',
  'network_type': type,
  'lan_signaling_url': 'https://sig.example',
  'access_token': 'tok',
});

void main() {
  group('NetworkCredential visibility', () {
    test(
      'permissioned-providers is Public (shared members can share models)',
      () {
        final cred = _credOfType('permissioned-providers');
        expect(cred.isPublic, isTrue);
        expect(cred.visibilityLabel, 'Public');
      },
    );

    test(
      'permissioned-public is Private, despite the "public" in its name',
      () {
        final cred = _credOfType('permissioned-public');
        expect(cred.isPublic, isFalse);
        expect(cred.visibilityLabel, 'Private');
      },
    );

    test('plain permissioned defaults to Private', () {
      final cred = _credOfType('permissioned');
      expect(cred.isPublic, isFalse);
      expect(cred.visibilityLabel, 'Private');
    });
  });
}
