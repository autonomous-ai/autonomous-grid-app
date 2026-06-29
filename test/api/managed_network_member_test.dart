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
          jsonDecode(raw) as Map<String, dynamic>);

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

  group('ManagedMemberRole', () {
    test('wire values match the API contract, without admin', () {
      expect(ManagedMemberRole.values.map((r) => r.wire),
          ['consumer', 'provider', 'both']);
    });
  });
}
