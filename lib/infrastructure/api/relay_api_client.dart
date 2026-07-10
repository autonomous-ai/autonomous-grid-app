import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/grid_overview.dart';

/// The relay's read APIs the app polls for a grid: the OpenAI-style model list
/// and the richer grid overview.
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
      connect: const Duration(seconds: 2),
      request: const Duration(seconds: 3),
      response: const Duration(seconds: 4),
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
      connect: const Duration(seconds: 3),
      request: const Duration(seconds: 4),
      response: const Duration(seconds: 6),
    );
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const RelayUnavailable();
    return GridOverview.fromJson(decoded.cast<String, dynamic>());
  }

  /// Shared GET: bearer auth, per-stage timeouts, 2xx-or-throw, always closes the
  /// client. A non-200 becomes [RelayUnavailable] with its status; any transport
  /// error becomes [RelayUnavailable] with the [cause].
  Future<String> _get(
    Uri url,
    String apiKey, {
    required Duration connect,
    required Duration request,
    required Duration response,
  }) async {
    final client = HttpClient()..connectionTimeout = connect;
    try {
      final req = await client.getUrl(url).timeout(request);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      final res = await req.close().timeout(response);
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw RelayUnavailable(statusCode: res.statusCode);
      }
      return body;
    } on RelayUnavailable {
      rethrow;
    } on Object catch (e) {
      throw RelayUnavailable(cause: e);
    } finally {
      client.close(force: true);
    }
  }
}

/// The relay-read seam. A real HTTP client by default; override with a fake in
/// tests so the model/overview providers run offline and deterministic.
final relayApiClientProvider = Provider<RelayApiClient>(
  (ref) => const HttpRelayApiClient(),
);
