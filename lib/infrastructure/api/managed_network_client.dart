import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models/managed_network.dart';

/// Control-plane call to `POST /v1/grid/managed-networks`, authenticated with
/// the GridSession bearer (the `session_token` from `~/.grid/credentials.toml`).
///
/// Mirrors [LocalChatClient]: a thin [HttpClient] wrapper that returns
/// `(network, null)` on success or `(null, error)` on failure — it never throws.
class ManagedNetworkClient {
  const ManagedNetworkClient._();

  /// The endpoint path appended to the control-plane base URL.
  static const String _path = 'v1/grid/managed-networks';

  static Future<(ManagedNetwork?, String?)> create({
    required String apiUrl,
    required String sessionToken,
    required String name,
    required ManagedNetworkType type,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(endpoint(apiUrl));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer $sessionToken');
      request.add(utf8.encode(jsonEncode({
        'name': name,
        'network_type': type.wire,
      })));

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _errorFor(response.statusCode, body));
      }
      return (ManagedNetwork.fromJson(jsonDecode(body) as Map<String, dynamic>), null);
    } on TimeoutException {
      return (null, "The server didn't respond in time. Try again.");
    } on SocketException catch (e) {
      return (null, "Couldn't reach the Grid control plane: ${e.message}");
    } on Object catch (e) {
      return (null, "Couldn't create the network: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// The full create-managed-network URL for [apiUrl] (which may or may not end
  /// in `/`). Public so callers can log the same URL the request hits.
  static Uri endpoint(String apiUrl) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$_path');
  }

  /// Turns a non-2xx response into a user-facing message, preferring the
  /// server's own `detail`/`message`, with friendlier text for known codes.
  static String _errorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'Your session has expired. Sign in again.',
      402 => detail ?? "You've reached your plan's network limit.",
      409 => detail ?? 'You already own a network with this name.',
      422 => detail ?? 'Invalid name or network type.',
      _ => detail ?? 'Error $status.',
    };
  }

  /// Pulls a human message out of a FastAPI error body
  /// (`{"detail": ...}`), tolerating plain-string or validation-list shapes.
  static String? _detailOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final detail = decoded['detail'] ?? decoded['message'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] != null) return '${first['msg']}';
      }
    } on Object {
      // Non-JSON body — let the caller fall back to a generic message.
    }
    return null;
  }
}
