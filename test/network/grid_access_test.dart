import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_access.dart';

void main() {
  group('who can reach a grid', () {
    test('the open grid is reachable by anyone, under either wire value it '
        'has been shipped with', () {
      expect(gridAccessFor('permissionless'), GridAccess.anyone);
      expect(gridAccessFor('permissioned-providers'), GridAccess.anyone);
    });

    test('the one with "public" in its name is the invite-only one — the wire '
        'reads backwards and the share dialog must not repeat it', () {
      expect(gridAccessFor('permissioned-public'), GridAccess.restricted);
    });

    test('a domain grid is invite-only too: the domain says whose grid it is, '
        'not who may walk into it', () {
      expect(gridAccessFor('private-domain'), GridAccess.domain);
    });

    test('anything unrecognised lands on the narrowest reading, so a value '
        'nobody taught this cannot open a grid up by itself', () {
      expect(gridAccessFor('permissionless-v2'), GridAccess.restricted);
      expect(gridAccessFor(''), GridAccess.restricted);
    });
  });
}
