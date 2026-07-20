import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auto_router/logic/auto_router_models.dart';

void main() {
  group('AutoRouterConfig', () {
    test('reads the on/off state and the advisor chain in order', () {
      final config = AutoRouterConfig.fromJson({
        'enabled': true,
        'advisors': [
          {'provider': 'openai', 'model': 'gpt-5-mini'},
          {'provider': 'openai', 'model': null},
        ],
      });

      expect(config.enabled, isTrue);
      expect(config.hasAdvisors, isTrue);
      // A model-bearing advisor renders as `provider:model`…
      expect(config.advisors.first.token, 'openai:gpt-5-mini');
      // …a bare provider (no model) renders as just the provider.
      expect(config.advisors[1].token, 'openai');
    });

    test('an empty advisor list means nothing is ranking yet', () {
      final config = AutoRouterConfig.fromJson({'enabled': false});
      expect(config.enabled, isFalse);
      expect(config.hasAdvisors, isFalse);
    });

    test('a blank model string is treated as no model, not an empty token', () {
      final advisor = Advisor.fromJson({'provider': 'openai', 'model': '   '});
      expect(advisor.model, isNull);
      expect(advisor.token, 'openai');
    });
  });

  group('AdvisorCatalog', () {
    test('flattens every provider’s models into provider:model tokens', () {
      final catalog = AdvisorCatalog.fromJson({
        'providers': [
          {
            'provider': 'openai',
            'default_model': 'gpt-5-mini',
            'models': ['gpt-5-mini', 'gpt-4o-mini'],
          },
        ],
      });

      expect(catalog.allTokens, ['openai:gpt-5-mini', 'openai:gpt-4o-mini']);
      expect(catalog.providers.single.defaultModel, 'gpt-5-mini');
    });

    test('an empty catalog yields no options rather than throwing', () {
      final catalog = AdvisorCatalog.fromJson({});
      expect(catalog.allTokens, isEmpty);
    });

    test(
      'default token is the first provider name so enabling needs no pick',
      () {
        final catalog = AdvisorCatalog.fromJson({
          'providers': [
            {
              'provider': 'openai',
              'models': ['gpt-5-mini'],
            },
            {
              'provider': 'anthropic',
              'models': ['claude'],
            },
          ],
        });

        expect(catalog.defaultToken, 'openai');
      },
    );

    test('an empty catalog has no default token to enable with', () {
      expect(AdvisorCatalog.fromJson({}).defaultToken, isNull);
    });
  });
}
