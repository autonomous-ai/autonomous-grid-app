import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Canned [RelayApiClient] so the model/overview providers run offline: returns
/// the given values, or throws the given [RelayUnavailable] for the error paths.
class _FakeRelayApiClient implements RelayApiClient {
  _FakeRelayApiClient({
    List<String>? models,
    GridOverview? overview,
    this.error,
  }) : _models = models ?? const [],
       _overview = overview;

  final List<String> _models;
  final GridOverview? _overview;
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
    return _overview!;
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
