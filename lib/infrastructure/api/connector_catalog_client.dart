import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/connectors/logic/connector_catalog.dart';
import '../providers.dart';

/// A failed connectors-catalog call. [message] is the friendly line; the raw
/// detail rides along for the Debug tab. Mirrors [ModelCatalogError].
class ConnectorCatalogError {
  const ConnectorCatalogError(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() => message;
}

/// Reads the connectors catalog from the control plane
/// (`GET /v1/connectors`), the list of services the assistant can be linked to.
///
/// Returns `(entries, null)` on success or `(null, error)` on failure — never
/// throws, because a catalog that can't be fetched is a normal state here: the
/// caller falls back to the bundled copy (see [connectorCatalogProvider]).
class ConnectorCatalogClient {
  const ConnectorCatalogClient({
    required this.apiUrl,
    required this.sessionToken,
  });

  /// The endpoint path appended to the control-plane base URL.
  static const String path = 'v1/connectors';

  final String apiUrl;

  /// Null or empty when signed out — the call is skipped rather than sent
  /// unauthenticated, so a signed-out user gets the bundled catalog instantly
  /// instead of waiting on a 401.
  final String? sessionToken;

  static Uri endpoint(String apiUrl) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$path');
  }

  Future<(List<ConnectorCatalogEntry>?, ConnectorCatalogError?)> fetch() async {
    final token = sessionToken;
    if (token == null || token.isEmpty) {
      return (null, const ConnectorCatalogError('Not signed in.'));
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(endpoint(apiUrl));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ConnectorCatalogError(
            "Couldn't load the connectors catalog.",
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      final entries = parseConnectorCatalogResponse(body);
      if (entries == null) {
        return (
          null,
          ConnectorCatalogError(
            "The connectors catalog came back in a shape this app doesn't "
            'understand.',
            statusCode: response.statusCode,
            body: body,
          ),
        );
      }
      return (entries, null);
    } on Object catch (error) {
      return (null, ConnectorCatalogError("Couldn't reach the grid: $error"));
    } finally {
      client.close(force: true);
    }
  }
}

/// Reads `{"status": 1, "data": {"connectors": [...], "total": n}}`.
///
/// Null means "not a catalog response at all" — the caller then falls back to
/// the bundled copy instead of showing an empty screen. An empty `connectors`
/// list is a valid answer and comes back as `[]`.
///
/// Individual entries are lenient: a row missing `code` or `label` is dropped
/// and the rest still show, because one renamed field must not blank the
/// screen.
List<ConnectorCatalogEntry>? parseConnectorCatalogResponse(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final data = decoded['data'];
  if (data is! Map<String, dynamic>) return null;
  final list = data['connectors'];
  if (list is! List) return null;

  final entries = <ConnectorCatalogEntry>[];
  for (final raw in list) {
    if (raw is! Map<String, dynamic>) continue;
    final code = raw['code'];
    final label = raw['label'];
    if (code is! String || code.isEmpty || label is! String || label.isEmpty) {
      continue;
    }
    entries.add(
      ConnectorCatalogEntry(
        id: raw['id'] is String ? raw['id'] as String : code,
        code: code,
        label: label,
        description: raw['description'] is String
            ? raw['description'] as String
            : '',
        imageUrl: raw['image_url'] is String ? raw['image_url'] as String : '',
        mcpUrl: raw['mcp_url'] is String ? raw['mcp_url'] as String : '',
        order: raw['order'] is int ? raw['order'] as int : null,
        // Anything but the literal "not_installed" counts as linked: the
        // backend may grow states (installed, needs_reauth) and a new one
        // should read as "there is something here", not as "not connected".
        installed: raw['status'] is String && raw['status'] != 'not_installed',
        authMethod: raw['supported_auth_method'] == 'manual'
            ? ConnectorAuthMethod.manual
            : ConnectorAuthMethod.app,
      ),
    );
  }
  return sortCatalog(entries);
}

/// The catalog client for the signed-in session. Overridable in tests so no
/// suite ever reaches the network.
final connectorCatalogClientProvider = Provider<ConnectorCatalogClient>((ref) {
  return ConnectorCatalogClient(
    apiUrl: ref.watch(gridApiUrlProvider),
    sessionToken: ref.watch(sessionProvider).sessionToken,
  );
});
