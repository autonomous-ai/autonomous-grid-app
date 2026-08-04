import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/connectors/logic/composio_toolkit.dart';
import '../providers.dart';
import 'connector_gateway_client.dart';

/// Reads Composio's catalog — **through Grid's own backend, never directly.**
///
/// **Why the detour.** Composio authenticates every request, browsing included:
/// `GET /api/v3/toolkits` with no key answers `401 Auth_NoAuthProvided`, and
/// with a malformed one `401 Auth_Unauthorized` (measured 2026-08-04). There is
/// no public endpoint — `/api/v1/apps` is `410 Gone`, and the categories
/// endpoint is behind the same wall. So somebody has to hold a key.
///
/// It cannot be this app. A desktop binary ships to every user, and a key
/// compiled into one is a key anybody can read out of it; worse, a single
/// embedded project key would put every user's connected accounts in one
/// Composio project. The backend holds it instead, and this client sends the
/// session Bearer the rest of the control plane already uses — so the secret
/// stays server-side and the user signs in once, to Grid.
///
/// That is the one real difference from the directory this replaces. Smithery's
/// registry answered unauthenticated, so browsing worked before any sign-in;
/// here an unauthenticated user gets [notSignedIn] and the screen says so.
///
/// **The proxy is expected to be transparent.** It attaches `x-api-key` and
/// passes Composio's response body through unchanged, which is why the parsing
/// in `ComposioToolkit` follows Composio's field names exactly. Anything the
/// backend reshapes is a second contract to keep in sync for no gain.
///
/// Same `(value, error)` shape as [ConnectorGatewayClient], and for the same
/// reason: every call sits behind a button, and a button needs a sentence to
/// show rather than an exception to swallow.
class ComposioCatalogClient {
  const ComposioCatalogClient({
    required this.apiUrl,
    required this.sessionToken,
    this.timeout = const Duration(seconds: 20),
  });

  final String apiUrl;
  final String? sessionToken;
  final Duration timeout;

  /// Shown when there is no session to authenticate the proxy call with.
  ///
  /// A distinct sentence rather than a generic failure: this is the one error
  /// on this path the user can actually do something about.
  static const String notSignedIn = 'Sign in to Grid to browse connectors.';

  /// Returned while the backend has not shipped the proxy yet.
  ///
  /// Kept recognisable — see [isNotDeployed] — because it is the one failure
  /// that means "ask again later with a different source", not "tell the user".
  static const String notDeployed =
      'The connector directory is not available on this account yet.';

  /// Whether [error] is the backend saying it has no such route.
  ///
  /// The migration to Composio landed in the app before the endpoint existed
  /// server-side. Distinguishing "route missing" from "Composio said no" is
  /// what lets the catalog fall back to the previous directory instead of
  /// showing an empty screen for however long the two sides are out of step.
  static bool isNotDeployed(String? error) => error == notDeployed;

  /// Whether [error] is this client refusing for want of a session.
  ///
  /// Separate from [isNotDeployed] because the two mean different things to a
  /// caller that has a second source: one says "this backend cannot answer
  /// yet", the other "this *user* cannot ask". Both are reasons to try the
  /// other directory rather than to show an empty screen — measured on the live
  /// backend 2026-08-04, the proxy route answers `404` before it ever checks a
  /// bearer, so a signed-out user reaches neither Composio nor a useful error.
  static bool isNotSignedIn(String? error) => error == notSignedIn;

  /// One page of the catalog.
  ///
  /// [cursor] continues a previous page — Composio's own opaque token, passed
  /// back verbatim. [sort] is sent as `sort_by`; unlike the previous directory,
  /// this one really does order the whole catalog rather than the page.
  Future<(ComposioPage?, String?)> toolkits({
    String search = '',
    int limit = 50,
    String? cursor,
    ComposioToolkitSort sort = ComposioToolkitSort.mostUsed,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'sort_by': sort.parameter,
      if (search.trim().isNotEmpty) 'search': search.trim(),
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    return _get(
      'composio/toolkits',
      query: query,
      parse: ComposioPage.fromJson,
    );
  }

  /// One toolkit by its slug.
  ///
  /// **A real endpoint, which the previous directory did not have.** Looking up
  /// a connected-but-unlisted connector used to mean searching for the words in
  /// its id and hoping a row matched exactly, because every `/servers/<name>`
  /// variant answered 404. Composio addresses toolkits by slug, so the lookup
  /// is now a question with an answer instead of a heuristic.
  Future<(ComposioToolkit?, String?)> toolkit(String slug) {
    final trimmed = slug.trim();
    if (trimmed.isEmpty) return Future.value((null, 'No connector named.'));
    return _get(
      'composio/toolkits/${Uri.encodeComponent(trimmed)}',
      parse: ComposioToolkit.fromJson,
    );
  }

  Future<(T?, String?)> _get<T>(
    String path, {
    required T? Function(Object? raw) parse,
    Map<String, String>? query,
  }) async {
    final token = sessionToken;
    if (token == null || token.isEmpty) return (null, notSignedIn);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      var uri = ConnectorGatewayClient.endpoint(apiUrl, path);
      if (query != null && query.isNotEmpty) {
        uri = uri.replace(queryParameters: query);
      }
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, _failureSentence(response.statusCode));
      }
      final parsed = parse(jsonDecode(body));
      if (parsed == null) {
        return (
          null,
          "The directory answered in a shape this app doesn't understand.",
        );
      }
      return (parsed, null);
    } on Object catch (error) {
      // The type, not the object: a SocketException's `toString` carries the
      // full URI, and the user's search text rides in that URI.
      return (null, "Couldn't reach the directory (${error.runtimeType}).");
    } finally {
      client.close(force: true);
    }
  }

  String _failureSentence(int status) => switch (status) {
    // 404 is the backend having no such route, not Composio having no such
    // toolkit — the proxy answers 200 with an empty page for that.
    404 || 501 => notDeployed,
    401 || 403 => notSignedIn,
    429 => 'The directory is rate-limiting this account. Try again shortly.',
    >= 500 => 'The directory had a problem ($status) — try again shortly.',
    _ => 'The directory answered $status.',
  };
}

final composioCatalogClientProvider = Provider<ComposioCatalogClient>((ref) {
  return ComposioCatalogClient(
    apiUrl: ref.watch(gridApiUrlProvider),
    sessionToken: ref.watch(sessionProvider).sessionToken,
  );
});
