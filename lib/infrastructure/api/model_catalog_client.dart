import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models/model_catalog.dart';
import 'models/model_detail.dart';

/// A failed Model Catalog call. [message] is the friendly line for the UI;
/// [statusCode]/[body] carry the raw detail for the Debug tab. [sessionExpired]
/// flags a 401 so callers can route the user to sign in rather than retry.
class ModelCatalogError {
  const ModelCatalogError(
    this.message, {
    this.statusCode,
    this.body,
    this.sessionExpired = false,
  });

  final String message;
  final int? statusCode;
  final String? body;
  final bool sessionExpired;

  String get debugDetail {
    final raw = body?.trim();
    if (raw == null || raw.isEmpty || raw == message) return message;
    final clipped = raw.length > 1000 ? '${raw.substring(0, 1000)}…' : raw;
    return '$message\n$clipped';
  }
}

/// Control-plane call to `POST /v1/grid/catalog`, authenticated with the
/// GridSession bearer (the `session_token` from `~/.grid/credentials.toml`).
///
/// A thin [HttpClient] wrapper mirroring [ManagedNetworkClient]: returns
/// `(suggestion, null)` on success or `(null, error)` on failure — never throws.
class ModelCatalogClient {
  const ModelCatalogClient._();

  /// The endpoint path appended to the control-plane base URL.
  static const String _path = 'v1/grid/catalog';

  /// Suggest mode — the ranked models for [device] (the raw object from
  /// `grid device-info --json`, forwarded verbatim under `device`).
  static Future<(CatalogSuggestion?, ModelCatalogError?)> suggest({
    required String apiUrl,
    required String sessionToken,
    required Map<String, dynamic> device,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(endpoint(apiUrl));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(utf8.encode(jsonEncode({'device': device})));

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ModelCatalogError(
            _errorFor(response.statusCode, body),
            statusCode: response.statusCode,
            body: body,
            sessionExpired: response.statusCode == 401,
          ),
        );
      }
      final suggestion = parseSuggestResponse(body);
      if (suggestion == null) {
        return (
          null,
          ModelCatalogError(
            'The catalog returned an unexpected response.',
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (suggestion, null);
    } on TimeoutException {
      return (
        null,
        const ModelCatalogError("The catalog didn't respond in time."),
      );
    } on SocketException catch (e) {
      return (
        null,
        ModelCatalogError("Couldn't reach the catalog: ${e.message}"),
      );
    } on Object catch (e) {
      return (null, ModelCatalogError("Couldn't load suggestions: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// The catalog URL for [apiUrl] (which may or may not end in `/`). Public so
  /// callers can log the same URL the request hits.
  static Uri endpoint(String apiUrl) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$_path');
  }

  /// Turns a non-2xx response into a user-facing message, preferring the
  /// server's own `detail`, with friendlier text for the codes the doc names.
  static String _errorFor(int status, String body) {
    final detail = _detailOf(body);
    return switch (status) {
      401 => 'Your session has expired. Sign in again.',
      422 => detail ?? "Couldn't read this computer's details.",
      502 || 503 => detail ?? 'The catalog is warming up. Try again shortly.',
      _ => detail ?? 'Error $status.',
    };
  }

  /// Pulls a human message out of a FastAPI error body (`{"detail": ...}`),
  /// tolerating plain-string or validation-list shapes.
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

  /// `POST /v1/grid/catalog` with `device` absent — the list/filter mode.
  ///
  /// [query] is the sidebar's search text, sent as `q` (the API matches it
  /// against `repo_id`). [sort] is omitted from the body when null or empty, so
  /// a plain search doesn't pin the results to a ranking the user didn't pick —
  /// the server then applies its own default.
  static Future<(List<CatalogListEntry>?, ModelCatalogError?)> list({
    required String apiUrl,
    required String sessionToken,
    String? sort = 'trending',
    String? query,
    int pageSize = 50,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
      final uri = Uri.parse('$base$_path');
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      request.add(
        utf8.encode(
          jsonEncode({
            if (sort != null && sort.isNotEmpty) 'sort': sort,
            if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
            'page_size': pageSize,
          }),
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ModelCatalogError(
            _errorFor(response.statusCode, body),
            statusCode: response.statusCode,
            body: body,
            sessionExpired: response.statusCode == 401,
          ),
        );
      }
      final entries = parseCatalogList(body);
      if (entries == null) {
        return (
          null,
          ModelCatalogError(
            'The catalog returned an unexpected response.',
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (entries, null);
    } on TimeoutException {
      return (
        null,
        const ModelCatalogError("The catalog didn't respond in time."),
      );
    } on SocketException catch (e) {
      return (
        null,
        ModelCatalogError("Couldn't reach the catalog: ${e.message}"),
      );
    } on Object catch (e) {
      return (null, ModelCatalogError("Couldn't load the catalog: $e"));
    } finally {
      client.close(force: true);
    }
  }

  /// `GET /v1/grid/catalog/{repo_id}?device=<json>` — full model detail with
  /// per-version status when [device] is non-null. Returns `(detail, null)` on
  /// success or `(null, error)` on failure — never throws.
  static Future<(ModelDetail?, ModelCatalogError?)> detail({
    required String apiUrl,
    required String sessionToken,
    required String repoId,
    Map<String, dynamic>? device,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
      final path = 'v1/grid/catalog/${Uri.encodeComponent(repoId)}';
      final query = device == null
          ? ''
          : '?device=${Uri.encodeQueryComponent(jsonEncode(device))}';
      final request = await client.getUrl(Uri.parse('$base$path$query'));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ModelCatalogError(
            _errorFor(response.statusCode, body),
            statusCode: response.statusCode,
            body: body,
            sessionExpired: response.statusCode == 401,
          ),
        );
      }
      final detail = parseModelDetail(body);
      if (detail == null) {
        return (
          null,
          ModelCatalogError(
            'The catalog returned an unexpected response.',
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (detail, null);
    } on TimeoutException {
      return (
        null,
        const ModelCatalogError("The catalog didn't respond in time."),
      );
    } on SocketException catch (e) {
      return (
        null,
        ModelCatalogError("Couldn't reach the catalog: ${e.message}"),
      );
    } on Object catch (e) {
      return (null, ModelCatalogError("Couldn't load model details: $e"));
    } finally {
      client.close(force: true);
    }
  }
}
