import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/node_setup/logic/media_status.dart';
import 'package:grid_app/features/node_setup/logic/node_capabilities.dart';
import 'package:grid_app/features/onboarding/logic/onboarding_choice_controller.dart';
import 'package:grid_app/infrastructure/state/onboarding_store.dart';

/// A machine that already has the engine and the assistant — so "run local"
/// installs nothing and the controller records the choice without touching the
/// CLI (the install path is exercised by node_setup_controller's own tests).
NodeCapabilities _readyCaps() => const NodeCapabilities(
  textBackends: [],
  engine: EngineStatus(llamaInstalled: true),
  media: MediaStatus.notInstalled,
  localModelCount: 0,
  hasAgent: true,
);

void main() {
  group(
    'inviteDomainPrefill — pre-fill the invite with the inviter’s domain',
    () {
      test('offers the domain so only the name is left to type', () {
        expect(inviteDomainPrefill('dev@autonomous.ai'), '@autonomous.ai');
      });

      test('is null with no email — the field stays a plain placeholder', () {
        expect(inviteDomainPrefill(null), isNull);
      });

      test('is null for a malformed email rather than a lone "@"', () {
        expect(inviteDomainPrefill('no-at-sign'), isNull);
        expect(inviteDomainPrefill('trailing@'), isNull);
      });

      test(
        'uses the last "@" so a plus-addressed local part is not mistaken for '
        'the domain',
        () {
          expect(inviteDomainPrefill('a@b@company.com'), '@company.com');
        },
      );
    },
  );

  group('OnboardingChoiceController', () {
    late Directory tmp;
    late File storeFile;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid_choice_test');
      storeFile = File('${tmp.path}/onboarding.json');
    });
    tearDown(() => tmp.delete(recursive: true));

    ProviderContainer build() {
      final c = ProviderContainer(
        overrides: [
          onboardingStoreProvider.overrideWithValue(
            OnboardingStore(file: storeFile),
          ),
          nodeCapabilitiesProvider.overrideWith((ref) async => _readyCaps()),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      '"set up later" records the choice so the fork is not shown again',
      () {
        final c = build();
        c.read(onboardingChoiceControllerProvider.notifier).chooseLater();

        expect(c.read(onboardingDecisionProvider), OnboardingDecision.later);
        expect(
          OnboardingStore(file: storeFile).load(),
          OnboardingDecision.later,
        );
      },
    );

    test(
      '"run local" records the local choice and settles back to idle',
      () async {
        final c = build();
        await c.read(onboardingChoiceControllerProvider.notifier).chooseLocal();

        expect(c.read(onboardingDecisionProvider), OnboardingDecision.local);
        expect(
          c.read(onboardingChoiceControllerProvider),
          isA<OnboardingChoiceIdle>(),
        );
        expect(
          OnboardingStore(file: storeFile).load(),
          OnboardingDecision.local,
        );
      },
    );
  });
}
