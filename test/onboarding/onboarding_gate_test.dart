import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/onboarding/logic/onboarding_gate.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/api/models/media_event.dart';
import 'package:grid_app/infrastructure/state/onboarding_store.dart';

GridOverview _overview({
  List<OverviewNode> nodes = const [],
  List<OverviewModel> models = const [],
}) => GridOverview(
  stats: const GridStats(models: 0, nodes: 0),
  models: models,
  nodes: nodes,
);

OverviewNode _node({
  bool online = true,
  String? model,
  List<String> models = const [],
}) => OverviewNode(name: 'n', online: online, model: model, models: models);

void main() {
  group('gridServesChatModel — is a model answering on the grid right now', () {
    test('an online node serving a chat model counts', () {
      expect(
        gridServesChatModel(_overview(nodes: [_node(model: 'qwen')])),
        isTrue,
      );
    });

    test('an offline node with a model does not — nothing is answering', () {
      expect(
        gridServesChatModel(
          _overview(nodes: [_node(online: false, model: 'qwen')]),
        ),
        isFalse,
      );
    });

    test('a media-only node is not a chat model', () {
      expect(
        gridServesChatModel(
          _overview(
            nodes: [
              _node(models: [kCapImageGenerate]),
            ],
          ),
        ),
        isFalse,
      );
    });

    test('the virtual auto router alone does not count — /models lists it even '
        'when no node is serving', () {
      expect(
        gridServesChatModel(
          _overview(models: const [OverviewModel(id: 'auto')]),
        ),
        isFalse,
      );
    });

    test('an online node plus an advertised chat model counts, even when the '
        'node record itself is bare', () {
      expect(
        gridServesChatModel(
          _overview(
            nodes: [_node()],
            models: const [OverviewModel(id: 'qwen')],
          ),
        ),
        isTrue,
      );
    });

    test('an online node advertising only the virtual auto router does not '
        'count — routing has nothing real to land on, so setup must show', () {
      expect(
        gridServesChatModel(
          _overview(
            nodes: [_node()],
            models: const [OverviewModel(id: 'auto')],
          ),
        ),
        isFalse,
      );
    });

    test('an empty grid has nothing to chat with', () {
      expect(gridServesChatModel(_overview()), isFalse);
    });
  });

  group('routeFor — where onboarding sends the user', () {
    const undecided = null;

    test('a user who already chose a path goes straight in, whatever the grid '
        'looks like', () {
      expect(
        routeFor(
          decision: OnboardingDecision.openai,
          hasEngine: false,
          hasLocalModel: false,
          overview: const AsyncValue.loading(),
        ),
        OnboardingRoute.home,
      );
    });

    test('an established local host (engine + a model on disk) is never parked '
        'at the choice screen', () {
      expect(
        routeFor(
          decision: undecided,
          hasEngine: true,
          hasLocalModel: true,
          overview: const AsyncValue.loading(),
        ),
        OnboardingRoute.home,
      );
    });

    test('a first user on an empty grid is asked how it gets a model', () {
      expect(
        routeFor(
          decision: undecided,
          hasEngine: false,
          hasLocalModel: false,
          overview: AsyncValue.data(_overview()),
        ),
        OnboardingRoute.choose,
      );
    });

    test(
      'joining a grid that already serves a model lands the user in chat',
      () {
        expect(
          routeFor(
            decision: undecided,
            hasEngine: false,
            hasLocalModel: false,
            overview: AsyncValue.data(_overview(nodes: [_node(model: 'qwen')])),
          ),
          OnboardingRoute.home,
        );
      },
    );

    test(
      'while the grid check is loading, hold a splash — do not flash the fork',
      () {
        expect(
          routeFor(
            decision: undecided,
            hasEngine: false,
            hasLocalModel: false,
            overview: const AsyncValue.loading(),
          ),
          OnboardingRoute.resolving,
        );
      },
    );

    test(
      'a relay hiccup sends the user in rather than blocking them at a fork',
      () {
        expect(
          routeFor(
            decision: undecided,
            hasEngine: false,
            hasLocalModel: false,
            overview: AsyncValue.error(
              const GridOverviewUnavailable('offline'),
              StackTrace.empty,
            ),
          ),
          OnboardingRoute.home,
        );
      },
    );
  });
}
