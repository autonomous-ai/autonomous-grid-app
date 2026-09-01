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

/// What one catalog call produced: the parsed [value] and the exact [body] it
/// was read from, or the [error] that stopped it — never both.
///
/// [body] is here for the fallback cache. Saving the bytes rather than a
/// re-encoding of [value] is what lets a stored copy parse exactly like a live
/// answer, however the API grows.
typedef CatalogRead<T> = ({T? value, String? body, ModelCatalogError? error});

/// Control-plane call to `POST /v1/grid/catalog`, authenticated with the
/// GridSession bearer (the `session_token` from `~/.grid/credentials.toml`).
///
/// A thin [HttpClient] wrapper mirroring [ManagedNetworkClient]: every endpoint
/// returns a [CatalogRead] and never throws.
class ModelCatalogClient {
  const ModelCatalogClient._();

  /// The endpoint path appended to the control-plane base URL.
  static const String _path = 'v1/grid/catalog';

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _readTimeout = Duration(seconds: 30);

  /// Suggest mode — the ranked models for [device] (the raw object from
  /// `grid device-info --json`, forwarded verbatim under `device`).
  static Future<CatalogRead<CatalogSuggestion>> suggest({
    required String apiUrl,
    required String sessionToken,
    required Map<String, dynamic> device,
  }) async => _parsed(
    await _send(
      uri: endpoint(apiUrl),
      sessionToken: sessionToken,
      jsonBody: {'device': device},
      failure: "Couldn't load suggestions",
    ),
    parseSuggestResponse,
  );

  /// `POST /v1/grid/catalog` with `device` absent — the list/filter mode.
  ///
  /// [query] is the sidebar's search text, sent as `q` (the API matches it
  /// against `repo_id`). [sort] is omitted from the body when null or empty, so
  /// a plain search doesn't pin the results to a ranking the user didn't pick —
  /// the server then applies its own default.
  static Future<CatalogRead<List<CatalogListEntry>>> list({
    required String apiUrl,
    required String sessionToken,
    String? sort = 'trending',
    String? query,
    int pageSize = 50,
  }) async => _parsed(
    await _send(
      uri: endpoint(apiUrl),
      sessionToken: sessionToken,
      jsonBody: {
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        'page_size': pageSize,
      },
      failure: "Couldn't load the catalog",
    ),
    parseCatalogList,
  );

  /// `GET /v1/grid/catalog/{repo_id}?device=<json>` — full model detail with
  /// per-version status when [device] is non-null.
  static Future<CatalogRead<ModelDetail>> detail({
    required String apiUrl,
    required String sessionToken,
    required String repoId,
    Map<String, dynamic>? device,
  }) async => _parsed(
    await _send(
      uri: detailEndpoint(apiUrl, repoId: repoId, device: device),
      sessionToken: sessionToken,
      failure: "Couldn't load model details",
    ),
    parseModelDetail,
  );

  /// The catalog URL for [apiUrl] (which may or may not end in `/`). Public so
  /// callers can log the same URL the request hits.
  static Uri endpoint(String apiUrl) => Uri.parse('${_base(apiUrl)}$_path');

  /// The per-model URL, with the device profile attached as a query parameter
  /// when there is one to send.
  static Uri detailEndpoint(
    String apiUrl, {
    required String repoId,
    Map<String, dynamic>? device,
  }) {
    final path = '${_base(apiUrl)}$_path/${Uri.encodeComponent(repoId)}';
    if (device == null) return Uri.parse(path);
    return Uri.parse(
      '$path?device=${Uri.encodeQueryComponent(jsonEncode(device))}',
    );
  }

  static String _base(String apiUrl) =>
      apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';

  /// One authenticated call, returning the response body or the failure. Every
  /// endpoint above is this plus a parser, so a timeout, a 401 and a 502 read
  /// the same whichever one the user happens to be waiting on.
  ///
  /// [jsonBody] non-null makes it a POST with that object as the payload;
  /// null makes it a GET. [failure] is the lead-in for anything unforeseen.
  static Future<(String?, ModelCatalogError?)> _send({
    required Uri uri,
    required String sessionToken,
    required String failure,
    Object? jsonBody,
  }) async {
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final request = jsonBody == null
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      if (jsonBody != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.add(utf8.encode(jsonEncode(jsonBody)));
      }

      final response = await request.close().timeout(_readTimeout);
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
      return (body, null);
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
      return (null, ModelCatalogError('$failure: $e'));
    } finally {
      client.close(force: true);
    }
  }

  /// Runs [parse] over a body that arrived, mapping one the parser can't read
  /// to the same "unexpected response" failure for every endpoint. The body is
  /// carried on the error so the Debug tab still shows what actually came back.
  static CatalogRead<T> _parsed<T>(
    (String?, ModelCatalogError?) response,
    T? Function(String body) parse,
  ) {
    final (body, error) = response;
    if (error != null || body == null) {
      return (value: null, body: null, error: error);
    }
    final value = parse(body);
    if (value == null) {
      return (
        value: null,
        body: null,
        error: ModelCatalogError(
          'The catalog returned an unexpected response.',
          body: body,
        ),
      );
    }
    return (value: value, body: body, error: null);
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
}
