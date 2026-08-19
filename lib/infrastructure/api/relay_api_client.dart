import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/logic/turn_model_share.dart';
import 'models/grid_overview.dart';

/// The relay's read APIs the app polls for a grid: the OpenAI-style model list,
/// the richer grid overview, and which models actually served a window of
/// requests.
///
/// A seam (interface + [HttpRelayApiClient]) so the providers that consume it
/// can be unit-tested against a fake instead of a live relay — mirroring how the
/// rest of the app fakes `GridCliService`. Data access lives here, not inline in
/// the providers, per the layering rule (presentation → logic → infrastructure).
abstract interface class RelayApiClient {
  /// `GET {baseUrl}/models` → the advertised model ids. Throws [RelayUnavailable]
  /// on a non-200 or a transport failure; a 200 with an unexpected body yields an
  /// empty list.
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  });

  /// `GET {baseUrl}/grid/overview` → the parsed overview. Throws
  /// [RelayUnavailable] (carrying the HTTP status when there is one) on failure.
  Future<GridOverview> overview({
    required String baseUrl,
    required String apiKey,
  });

  /// `GET {baseUrl}/usage?since=&until=` → which models served this consumer's
  /// requests in the window, and how many each.
  ///
  /// The only way to learn what an `auto` turn actually ran on: the agent CLI
  /// makes the relay calls, so the app never sees their responses. Throws
  /// [RelayUnavailable] like the others — including **404 on a grid whose master
  /// predates the endpoint**, which is the common case while the fleet is mid
  /// rollout and must read as "no data", never as an error the user sees.
  Future<List<ModelShare>> usage({
    required String baseUrl,
    required String apiKey,
    required DateTime since,
    DateTime? until,
  });
}

/// A relay read failed. [statusCode] is the HTTP status when the request
/// completed with a non-2xx, or null for a transport error (timeout, socket) or
/// a malformed body; [cause] keeps the underlying error for the command log.
class RelayUnavailable implements Exception {
  const RelayUnavailable({this.statusCode, this.cause});

  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'RelayUnavailable(status: $statusCode${cause == null ? '' : ', $cause'})';
}

/// How long `GET /models` may take, end to end.
///
/// Generous on purpose. The relay answers this one in ~150ms, and the timeouts
/// in the log were never it being slow: they fired while the app's own event
/// loop was stalled, so a 3-second budget reported itself 9 seconds late. A
/// budget that outlives a stall costs a healthy call nothing.
///
/// **The trade:** a relay that is genuinely unreachable now leaves the chat's
/// model picker on its loading state for this long instead of three seconds.
/// That is the right way round — the list is what the whole picker stands on,
/// and "still asking" is honest where a fast empty answer was not.
const _kModelsDeadline = Duration(seconds: 30);

/// How long `GET /grid/overview` may take, end to end — its previous
/// per-stage budgets added up to about this.
const _kOverviewDeadline = Duration(seconds: 10);

/// How long `GET /usage` may take, end to end — its previous per-stage
/// budgets added up to about this.
const _kUsageDeadline = Duration(seconds: 7);

/// Real [RelayApiClient] over `dart:io` [HttpClient] — matching the rest of the
/// app's HTTP (no `package:http`). Each call opens a short-lived client and
/// always closes it.
class HttpRelayApiClient implements RelayApiClient {
  const HttpRelayApiClient();

  @override
  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) async {
    final body = await _get(
      Uri.parse('$baseUrl/models'),
      apiKey,
      deadline: _kModelsDeadline,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['data'] is! List) return const [];
    return (decoded['data'] as List)
        .whereType<Map>()
        .map((m) => '${m['id']}')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  @override
  Future<GridOverview> overview({
    required String baseUrl,
    required String apiKey,
  }) async {
    final body = await _get(
      Uri.parse('$baseUrl/grid/overview'),
      apiKey,
      deadline: _kOverviewDeadline,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const RelayUnavailable();
    return GridOverview.fromJson(decoded.cast<String, dynamic>());
  }

  @override
  Future<List<ModelShare>> usage({
    required String baseUrl,
    required String apiKey,
    required DateTime since,
    DateTime? until,
  }) async {
    final query = {
      'since': '${since.toUtc().millisecondsSinceEpoch ~/ 1000}',
      if (until != null)
        'until': '${until.toUtc().millisecondsSinceEpoch ~/ 1000}',
    };
    final body = await _get(
      Uri.parse('$baseUrl/usage').replace(queryParameters: query),
      apiKey,
      // Tighter than the overview's: this runs on a timer while a turn is open,
      // and a caption that is late is worth less than one that never blocks.
      deadline: _kUsageDeadline,
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['models'] is! List) return const [];
    return [
      for (final row in decoded['models'] as List) ?ModelShare.fromJson(row),
    ];
  }

  /// Shared GET: bearer auth, one deadline for the whole call, 200-or-throw,
  /// always closes the client.
  ///
  /// **One budget, not three.** The stages used to be timed separately — the
  /// connection, then the response headers, and the body not at all — which
  /// made a failure report a number no caller had asked for: `TimeoutException
  /// after 0:00:03` on a call the log had timed at nine seconds. It also left
  /// the body unbounded, so a relay that sent headers and then went quiet hung
  /// the call for as long as the socket stayed open. [deadline] now covers DNS,
  /// TLS, headers and body together, so the number in the log is the budget the
  /// endpoint was actually given.
  ///
  /// A non-200 becomes [RelayUnavailable] with its status; any transport error
  /// becomes [RelayUnavailable] with the [cause].
  Future<String> _get(
    Uri url,
    String apiKey, {
    required Duration deadline,
  }) async {
    final client = HttpClient()..connectionTimeout = deadline;
    try {
      return await _read(client, url, apiKey).timeout(deadline);
    } on RelayUnavailable {
      rethrow;
    } on Object catch (e) {
      throw RelayUnavailable(cause: e);
    } finally {
      client.close(force: true);
    }
  }

  /// The request itself, with no clock of its own — [_get] owns the deadline,
  /// and force-closing the client there is what cuts a read short.
  Future<String> _read(HttpClient client, Uri url, String apiKey) async {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw RelayUnavailable(statusCode: res.statusCode);
    }
    return body;
  }
}

/// The relay-read seam. A real HTTP client by default; override with a fake in
/// tests so the model/overview providers run offline and deterministic.
final relayApiClientProvider = Provider<RelayApiClient>(
  (ref) => const HttpRelayApiClient(),
);
