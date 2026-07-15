import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/onboarding_store.dart';

void main() {
  late Directory tmp;
  late File file;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_onboarding_test');
    file = File('${tmp.path}/app/onboarding.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        onboardingStoreProvider.overrideWithValue(OnboardingStore(file: file)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('OnboardingStore', () {
    test('a fresh install has made no choice yet', () {
      expect(OnboardingStore(file: file).load(), isNull);
    });

    test(
      'round-trips the chosen path through disk so it survives a restart',
      () {
        OnboardingStore(file: file).save(OnboardingDecision.openai);
        expect(OnboardingStore(file: file).load(), OnboardingDecision.openai);
      },
    );

    test('a corrupt file reads as "not decided" instead of throwing', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{ not json');
      expect(OnboardingStore(file: file).load(), isNull);
    });

    test(
      'an unrecognised hand-edited decision reads as "not decided" — a broken '
      'file must never wedge the user out of the choice screen',
      () {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('{"decision": "teleport"}');
        expect(OnboardingStore(file: file).load(), isNull);
      },
    );
  });

  group('onboardingDecisionProvider', () {
    test('starts null and remembers the decision on disk once made', () {
      final c = container();
      expect(c.read(onboardingDecisionProvider), isNull);

      c
          .read(onboardingDecisionProvider.notifier)
          .decide(OnboardingDecision.local);

      expect(c.read(onboardingDecisionProvider), OnboardingDecision.local);
      expect(OnboardingStore(file: file).load(), OnboardingDecision.local);
    });

    test('a fresh controller restores what a prior session chose', () {
      OnboardingStore(file: file).save(OnboardingDecision.later);
      expect(
        container().read(onboardingDecisionProvider),
        OnboardingDecision.later,
      );
    });
  });
}
