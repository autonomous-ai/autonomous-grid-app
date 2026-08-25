import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_access_types.dart';
import 'package:grid_app/infrastructure/api/models/managed_network.dart';

void main() {
  group('which access rules a form may offer', () {
    test('an account on a company domain is offered all three', () {
      final types = accessTypesFor(canRestrictToDomain: true);

      expect(types, ManagedNetworkType.values);
    });

    test('a public-provider account is not offered the domain rule at all', () {
      // Restricting a grid "to my domain" on gmail.com would admit every Gmail
      // account. The server refuses it, so offering it here would be a choice
      // that 400s after the person has already committed to it.
      final types = accessTypesFor(canRestrictToDomain: false);

      expect(types, isNot(contains(ManagedNetworkType.domain)));
      expect(types, [ManagedNetworkType.restricted, ManagedNetworkType.anyone]);
    });

    test('the narrowest rule is the default for a new grid', () {
      // Opening a grid up later is one click; the people who used it while it
      // was open cannot be un-let-in.
      expect(ManagedNetworkType.fallback, ManagedNetworkType.restricted);
      expect(
        accessTypesFor(canRestrictToDomain: false),
        contains(ManagedNetworkType.fallback),
      );
    });
  });

  group('what the picker calls each rule', () {
    test('the domain rule names the domain — it IS the rule', () {
      // "My domain" is a pronoun the owner has to resolve themselves, and this
      // is the one control whose entire question is *which* domain gets in.
      //
      // The `@` and the plural are load-bearing: an account whose email domain
      // is autonomous.ai also has a **grid** named autonomous.ai, so the bare
      // "Only autonomous.ai" read as the name of that other grid rather than as
      // a rule about addresses. Reported from the running app on a grid called
      // Test-Grid.
      expect(
        accessLabelFor(ManagedNetworkType.domain, domain: 'clc.fitus.edu.vn'),
        '@clc.fitus.edu.vn emails',
      );
      expect(
        accessDescriptionFor(
          ManagedNetworkType.domain,
          domain: 'clc.fitus.edu.vn',
        ),
        contains('@clc.fitus.edu.vn'),
      );
    });

    test('without a domain it falls back rather than saying "Only null"', () {
      for (final blank in <String?>[null, '', '  ']) {
        expect(
          accessLabelFor(ManagedNetworkType.domain, domain: blank),
          ManagedNetworkType.domain.label,
        );
      }
    });

    test('the other two rules ignore the domain entirely', () {
      for (final type in [
        ManagedNetworkType.restricted,
        ManagedNetworkType.anyone,
      ]) {
        expect(accessLabelFor(type, domain: 'acme.dev'), type.label);
        expect(
          accessDescriptionFor(type, domain: 'acme.dev'),
          type.description,
        );
      }
    });
  });

  group('wire values', () {
    test('the names say what the rules MEAN, not what the wire calls them', () {
      // `permissioned-public` is the PRIVATE one — "public" there refers to the
      // signaling server being reachable, not to who may use the grid. Reading
      // the wire value as the meaning is the mistake this mapping prevents.
      expect(ManagedNetworkType.restricted.wire, 'permissioned-public');
      expect(ManagedNetworkType.domain.wire, 'domain-restricted');
      expect(ManagedNetworkType.anyone.wire, 'permissionless');
    });

    test('fromWire resolves every rule this picker offers', () {
      for (final type in ManagedNetworkType.values) {
        expect(ManagedNetworkType.fromWire(type.wire), type);
      }
    });

    test('fromWire returns null for a rule the picker cannot show', () {
      // Both are real types on live grids: `permissioned-providers` is what the
      // web's "Public" creates, `private-domain` is auto-provisioned per email
      // domain. Callers must render a sentence for these, not a picker — so the
      // absence has to be reported rather than defaulted away.
      expect(ManagedNetworkType.fromWire('permissioned-providers'), isNull);
      expect(ManagedNetworkType.fromWire('private-domain'), isNull);
      expect(ManagedNetworkType.fromWire(null), isNull);
      expect(ManagedNetworkType.fromWire(''), isNull);
    });
  });
}
