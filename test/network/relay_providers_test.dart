import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/turn_model_share.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

import 'package:grid_app/infrastructure/api/relay_api_client.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _network(String id) => NetworkCredential(
  networkId: id,
  name: id,
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// A relay overview payload, parsed the way the app parses a real one — so the
/// snapshots a test compares are built exactly as production builds them.
GridOverview _snapshot({List<String> models = const ['llama']}) =>
    GridOverview.fromJson({
      'grid': {'state': 'active'},
      'stats': {'models': models.length, 'nodes': 1},
      'models': [
        for (final id in models) {'id': id},
      ],
      'nodes': [
        {'name': 'mac', 'online': true, 'vram_gb': 16, 'models': models},
      ],
    });

/// Canned [RelayApiClient] so the model/overview providers run offline: returns
/// the given values, or throws the given [RelayUnavailable] for the error paths.
class _FakeRelayApiClient implements RelayApiClient {
  _FakeRelayApiClient({
    List<String>? models,
    GridOverview? overview,
    this.overviewBuilder,
    this.error,
  }) : _models = models ?? const [],
       _overview = overview;

  /// These tests are about the model and overview polls; `/usage` answers
  /// nothing, which is also what a grid whose master predates the endpoint
  /// does — so the app's degrade path is what runs here.
  @override
  Future<ConversationUsage> usage({
    required String baseUrl,
    required String apiKey,
    DateTime? since,
    DateTime? until,
    String? conversation,
    String? from,
    String? to,
  }) async {
    if (error != null) throw error!;
    return (models: const <ModelShare>[], last: null);
  }

  /// Same posture as `usage` above: these tests exercise the model and overview
  /// polls, so the member-usage read answers "no rollup here" — which is also
  /// what a master predating the endpoint does.
  @override
  Future<MemberUsageReport?> memberUsage({
    required String baseUrl,
    required String apiKey,
  }) async {
    if (error != null) throw error!;
    return null;
  }

  final List<String> _models;
  final GridOverview? _overview;

  /// Builds a *fresh* overview per call — what the real relay does. Lets a test
  /// re-poll and get an equal-but-not-identical snapshot, which is the only way
  /// to prove the app compares them by value.
  final GridOverview Function()? overviewBuilder;
  final RelayUnavailable? error;

  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) async {
    if (error != null) throw error!;
    return _models;
  }

  @override
  Future<GridOverview> overview({
    required String baseUrl,
    required String apiKey,
  }) async {
    if (error != null) throw error!;
    return overviewBuilder?.call() ?? _overview!;
  }
}

ProviderContainer _container(RelayApiClient client) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(
        CredentialsFile(
          networks: [_network('grid-foo')],
          activeNetwork: 'grid-foo',
        ),
      ),
      relayApiClientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

// Resolve an autoDispose async provider deterministically: an active listener
// keeps it alive, and a completer settles on the first value/error. We check
// `hasError`/`hasValue` (not `whenOrNull`) so we catch the error even while
// Riverpod is retrying it (retry keeps the state at loading-with-error).
Future<List<String>> _readModels(ProviderContainer c) {
  final completer = Completer<List<String>>();
  final sub = c.listen(networkModelsProvider, (_, next) {
    if (completer.isCompleted) return;
    if (next.hasError) {
      completer.completeError(next.error!, next.stackTrace);
    } else if (next.hasValue) {
      completer.complete(next.requireValue);
    }
  }, fireImmediately: true);
  addTearDown(sub.close);
  return completer.future;
}

Future<GridOverview> _readOverview(ProviderContainer c) {
  final completer = Completer<GridOverview>();
  final sub = c.listen(gridOverviewForProvider('grid-foo'), (_, next) {
    if (completer.isCompleted) return;
    if (next.hasError) {
      completer.completeError(next.error!, next.stackTrace);
    } else if (next.hasValue) {
      completer.complete(next.requireValue);
    }
  }, fireImmediately: true);
  addTearDown(sub.close);
  return completer.future;
}

void main() {
  group('networkModelsProvider', () {
    test('returns the ids the relay client resolves', () async {
      final c = _container(_FakeRelayApiClient(models: ['a', 'b']));
      expect(await _readModels(c), ['a', 'b']);
    });

    test('a relay advertising only the auto router resolves to no models, so '
        'the app never offers a model that cannot answer', () async {
      final c = _container(_FakeRelayApiClient(models: ['auto']));
      expect(await _readModels(c), isEmpty);
    });

    test('falls back to empty when the relay is unavailable', () async {
      final c = _container(
        _FakeRelayApiClient(error: const RelayUnavailable(statusCode: 401)),
      );
      expect(await _readModels(c), isEmpty);
    });
  });

  group('gridOverviewForProvider', () {
    test('returns the overview the relay client resolves', () async {
      final overview = GridOverview(
        stats: const GridStats(models: 2, nodes: 1),
        models: const [],
        nodes: const [],
      );
      final c = _container(_FakeRelayApiClient(overview: overview));
      final result = await _readOverview(c);
      expect(result.stats.models, 2);
    });

    test('maps a 503 to the friendly "no node online" message', () async {
      final c = _container(
        _FakeRelayApiClient(error: const RelayUnavailable(statusCode: 503)),
      );
      await expectLater(
        _readOverview(c),
        throwsA(
          isA<GridOverviewUnavailable>().having(
            (e) => e.message,
            'message',
            contains('No node is online'),
          ),
        ),
      );
    });

    test('a poll that brings back the same grid notifies nobody, so an '
        'unchanged grid never rebuilds the screens reading it', () async {
      // The relay hands back a new object every poll. Only value equality can
      // tell "same grid" from "new object", and everything derived from the
      // overview — the model list here — rebuilds on the difference.
      var served = ['llama'];
      final c = _container(
        _FakeRelayApiClient(overviewBuilder: () => _snapshot(models: served)),
      );

      var notified = 0;
      final sub = c.listen(gridModelsProvider, (previous, next) => notified++);
      addTearDown(sub.close);
      await pumpEventQueue();
      // Ignore the first resolve; we're measuring what a *re-poll* costs.
      notified = 0;

      c.invalidate(gridOverviewForProvider('grid-foo'));
      await pumpEventQueue();
      expect(notified, 0);

      // A grid that really did change still gets through.
      served = ['llama', 'qwen'];
      c.invalidate(gridOverviewForProvider('grid-foo'));
      await pumpEventQueue();
      expect(notified, 1);
      expect(c.read(gridModelsProvider).map((m) => m.id), ['llama', 'qwen']);
    });

    test('maps a transport error to the "unreachable" message', () async {
      final c = _container(
        _FakeRelayApiClient(
          error: const RelayUnavailable(cause: 'socket down'),
        ),
      );
      await expectLater(
        _readOverview(c),
        throwsA(
          isA<GridOverviewUnavailable>().having(
            (e) => e.message,
            'message',
            contains('unreachable'),
          ),
        ),
      );
    });
  });
}
