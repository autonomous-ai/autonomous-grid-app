import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/connectors/logic/smithery_server.dart';

/// Reads the public Smithery registry — a directory of hosted MCP servers.
///
/// **No credential, by design.** `GET /servers` answers unauthenticated, and
/// this client deliberately sends nothing: browsing a public directory should
/// not require the user to hold a Smithery account, and the sign-in that Connect
/// performs later is with the *server's own* authorization server, not with
/// Smithery's API. Nothing on this path is billable — see the note on
/// [SmitheryServer.mcpUrl] for why the free OAuth challenge is the whole
/// mechanism.
///
/// Same `(value, error)` shape as `ConnectorGatewayClient` and for the same
/// reason: every call sits behind a button, and a button needs a sentence to
/// show rather than an exception to swallow.
class SmitheryRegistryClient {
  const SmitheryRegistryClient({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  static const String _base = 'https://api.smithery.ai/servers';

  /// The registry's own filter token, appended to every query.
  ///
  /// Without it the unfiltered listing mixes in servers you install and run
  /// yourself: 7,500 entries total against 3,998 remote ones (measured
  /// 2026-07-31). Those have no URL to connect to, so they would be rows whose
  /// only possible outcome is a Connect that cannot work. The filter composes
  /// with a user's search — `notion is:remote` returns 120 — so searching and
  /// filtering are not in tension.
  static const String _remoteOnly = 'is:remote';

  /// One page of the directory, newest-first as the registry orders it.
  ///
  /// [query] is the user's search text, empty for the plain listing. Callers
  /// pass their own [pageSize] — `BrowseConnectorsController.pageSize` is the
  /// one the app actually uses, and the default here only keeps this callable on
  /// its own.
  Future<(SmitheryPage?, String?)> servers({
    int page = 1,
    int pageSize = 50,
    String query = '',
  }) async {
    final search = query.trim().isEmpty
        ? _remoteOnly
        : '${query.trim()} $_remoteOnly';
    final uri = Uri.parse(_base).replace(
      queryParameters: {'q': search, 'page': '$page', 'pageSize': '$pageSize'},
    );

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _failureSentence(response.statusCode));
      }
      final parsed = SmitheryPage.fromJson(jsonDecode(body));
      if (parsed == null) {
        return (
          null,
          "The directory answered in a shape this app doesn't understand.",
        );
      }
      return (parsed, null);
    } on Object catch (error) {
      // The type, not the object: a SocketException's toString carries the full
      // URI, and the search text rides in that URI.
      return (null, "Couldn't reach the directory (${error.runtimeType}).");
    } finally {
      client.close(force: true);
    }
  }

  String _failureSentence(int status) => switch (status) {
    404 => 'The directory has no such page (404).',
    429 => 'The directory is rate-limiting this computer. Try again shortly.',
    >= 500 => 'The directory had a problem ($status) — try again shortly.',
    _ => 'The directory answered $status.',
  };
}

final smitheryRegistryClientProvider = Provider<SmitheryRegistryClient>(
  (ref) => const SmitheryRegistryClient(),
);
