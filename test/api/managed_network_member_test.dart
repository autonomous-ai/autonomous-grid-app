import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/managed_network_member.dart';

void main() {
  group('ManagedNetworkMember.fromJson', () {
    test('parses a full member object', () {
      const raw = '''
      {"email": "a@example.com", "roles": ["consumer", "provider"],
       "status": "active", "payment_status": "paid"}''';

      final m = ManagedNetworkMember.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );

      expect(m.email, 'a@example.com');
      expect(m.roles, ['consumer', 'provider']);
      expect(m.status, 'active');
      expect(m.paymentStatus, 'paid');
    });

    test('tolerates missing roles and optional fields', () {
      final m = ManagedNetworkMember.fromJson(const {'email': 'b@example.com'});

      expect(m.email, 'b@example.com');
      expect(m.roles, isEmpty);
      expect(m.status, isNull);
      expect(m.paymentStatus, isNull);
    });
  });

  group('ManagedNetworkMember.isOwner', () {
    test('is true only when the member carries the admin role', () {
      const owner = ManagedNetworkMember(
        email: 'owner@example.com',
        roles: ['admin'],
      );
      const provider = ManagedNetworkMember(
        email: 'me@example.com',
        roles: ['provider', 'consumer'],
      );
      const noRoles = ManagedNetworkMember(email: 'x@example.com', roles: []);

      expect(owner.isOwner, isTrue);
      // Regression: a provider viewing the list must not read as the owner just
      // because they're the one looking at it.
      expect(provider.isOwner, isFalse);
      expect(noRoles.isOwner, isFalse);
    });
  });

  group('ManagedMemberRole', () {
    test('wire values match the API contract, without admin', () {
      expect(ManagedMemberRole.values.map((r) => r.wire), [
        'consumer',
        'provider',
        'both',
      ]);
    });
  });
}
