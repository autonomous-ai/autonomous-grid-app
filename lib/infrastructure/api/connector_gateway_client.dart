import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/logic/connector_token.dart';
import '../../features/auth/logic/session_controller.dart';
import '../../features/connectors/logic/connector_catalog.dart';
import '../providers.dart';

/// A gateway call that didn't work.
///
/// The gateway reports every failure as an HTTP status plus
/// `{"detail": "a readable English sentence"}`, so [message] is usually that
/// sentence verbatim — it is written for a person, and rewording it here would
/// only lose detail.
class ConnectorGatewayError {
  const ConnectorGatewayError(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  /// The session is gone; the user has to sign in again. Worth distinguishing
  /// because it's the one failure a retry can't fix.
  bool get isUnauthorized => statusCode == 401;

  /// The server is misconfigured or down. Not the user's fault and not theirs
  /// to fix — offer a retry, never instructions.
  bool get isServerFault => statusCode != null && statusCode! >= 500;

  @override
  String toString() => message;
}

/// The ticket for collecting an authorization the app was never handed.
///
/// Nothing comes back from the browser — no deep link, no loopback listener —
/// so [pickupCode] is the only way to ask for a result that arrived somewhere
/// else entirely.
class ConnectorAuthorization {
  const ConnectorAuthorization({
    required this.connector,
    required this.authorizeUrl,
    required this.pickupCode,
    this.pollInterval = const Duration(seconds: 2),
    this.expiresIn = const Duration(minutes: 10),
  });

  final String connector;

  /// Open in the *system* browser, never a webview. Single-use: pressing
  /// Connect again means calling `/start` again, never reusing this.
  final String authorizeUrl;

  final String pickupCode;

  /// How long to wait between polls — the server's number, because it knows its
  /// own load better than a constant here would.
  final Duration pollInterval;

  /// How long the authorization stays alive before the server forgets it.
  final Duration expiresIn;
}

/// Where one poll landed.
enum ConnectorPollStatus {
  /// The user hasn't finished in the browser yet.
  pending,

  /// Done, and this response carries the token. **Only ever returned once.**
  ready,

  /// The token exchange failed at the provider.
  failed,

  /// The user took longer than `expires_in`; the server forgot the request.
  expired,

  /// A `ready` was already collected. Reaching this means the app polled after
  /// it had its answer — a client bug, not a state worth explaining to a user.
  consumed,
}

/// One `/poll` answer.
class ConnectorPollResult {
  const ConnectorPollResult({
    required this.status,
    required this.connector,
    this.error = '',
    this.token,
  });

  final ConnectorPollStatus status;
  final String connector;

  /// The provider's own words, when [status] is [ConnectorPollStatus.failed].
  /// Raw and unpolished, so the screen pairs it with a sentence of its own
  /// rather than showing it alone.
  final String error;

  /// Present only on [ConnectorPollStatus.ready].
  ///
  /// ⚠️ **This is the one and only delivery.** Write it to disk before doing
  /// anything else with it — polling again returns `consumed` with no token,
  /// and there is no other way to get it back.
  final ConnectorToken? token;
}

/// The Grid connectors gateway: catalog, authorization, refresh, disconnect.
///
/// A deliberately dumb client. The gateway mints `state`, holds every
/// provider's `client_id` and `client_secret`, performs the code-for-token
/// exchange server-side, and renders the MCP entry per that provider's own
/// header convention. Adding a provider — even one with an unusual header like
/// `X-Figma-Token` — is a config row on their side and no app change at all.
///
/// Every method returns `(value, error)` and never throws: each one sits behind
/// a button, and a button needs a line to show rather than an exception to
/// swallow.
class ConnectorGatewayClient {
  const ConnectorGatewayClient({
    required this.apiUrl,
    required this.sessionToken,
    this.timeout = const Duration(seconds: 20),
  });

  /// The app's own control plane — same host, same session Bearer the catalog
  /// already uses. No second backend and no second sign-in.
  final String apiUrl;

  final String? sessionToken;

  final Duration timeout;

  /// Everything connector-related lives under this prefix.
  static const String pathPrefix = 'v1/grid';

  static Uri endpoint(String apiUrl, String path) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$pathPrefix/$path');
  }

  /// The catalog with this user's connection status. Never carries a token —
  /// those come only from [poll] and [refresh].
  Future<(List<ConnectorCatalogEntry>?, ConnectorGatewayError?)> connectors() {
    return _send(
      'GET',
      'connectors',
      parse: parseGatewayConnectors,
      failure: "Couldn't load the connectors.",
    );
  }

  /// Begin an authorization. The returned URL is single-use.
  Future<(ConnectorAuthorization?, ConnectorGatewayError?)> start(
    String connector,
  ) {
    return _send(
      'POST',
      'connectors/start',
      body: {'connector': connector},
      parse: (raw) => parseAuthorization(raw, fallbackConnector: connector),
      failure: "Couldn't start the sign-in.",
    );
  }

  /// Ask whether the authorization finished. A `ready` here is the only
  /// delivery of the token — see [ConnectorPollResult.token].
  Future<(ConnectorPollResult?, ConnectorGatewayError?)> poll(
    String pickupCode, {
    required String connector,
  }) {
    return _send(
      'POST',
      'connectors/poll',
      body: {'pickup_code': pickupCode},
      parse: (raw) => parsePollResult(raw, fallbackConnector: connector),
      failure: "Couldn't check the sign-in.",
    );
  }

  /// Renew a token before it expires. Only worth calling when the stored entry
  /// says the provider issues refresh tokens.
  Future<(ConnectorToken?, ConnectorGatewayError?)> refresh(String connector) {
    return _send(
      'POST',
      'connectors/refresh',
      body: {'connector': connector},
      parse: (raw) => parseTokenPayload(raw, fallbackConnector: connector),
      failure: "Couldn't refresh the connection.",
    );
  }

  /// Forget the credential server-side.
  ///
  /// This does **not** revoke access at the provider — only the user can do
  /// that, in the provider's own settings. Whatever the app says about
  /// disconnecting has to be honest about that.
  Future<(bool, ConnectorGatewayError?)> disconnect(String connector) async {
    final (ok, error) = await _send<bool>(
      'POST',
      'connectors/disconnect',
      body: {'connector': connector},
      // `disconnected: false` only means there was nothing stored to forget,
      // which is the end state we wanted either way.
      parse: (_) => true,
      failure: "Couldn't disconnect.",
    );
    return (ok ?? false, error);
  }

  Future<(T?, ConnectorGatewayError?)> _send<T>(
    String method,
    String path, {
    required T? Function(String body) parse,
    required String failure,
    Map<String, dynamic>? body,
  }) async {
    final token = sessionToken;
    if (token == null || token.isEmpty) {
      return (null, const ConnectorGatewayError('Not signed in.'));
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = endpoint(apiUrl, path);
      final request = method == 'GET'
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ConnectorGatewayError(
            // The server's own sentence beats ours whenever there is one.
            parseDetail(raw) ?? '$failure ${_httpHint(response.statusCode)}',
            statusCode: response.statusCode,
            body: raw,
          ),
        );
      }

      final parsed = parse(raw);
      if (parsed == null) {
        return (
          null,
          ConnectorGatewayError(
            "The grid answered in a shape this app doesn't understand.",
            statusCode: response.statusCode,
            body: raw,
          ),
        );
      }
      return (parsed, null);
    } on Object catch (error) {
      return (null, ConnectorGatewayError("Couldn't reach the grid: $error"));
    } finally {
      client.close(force: true);
    }
  }
}

/// What an HTTP failure means when the body carried no `detail`.
///
/// The status code is always named. A 404 once came back as an HTML page from
/// the wrong host, and without the code the user saw only "Couldn't start the
/// sign-in." — the one piece of evidence discarded (§10).
String _httpHint(int statusCode) {
  return switch (statusCode) {
    404 => 'The grid has no such endpoint (404).',
    401 || 403 => 'The grid refused this session ($statusCode).',
    >= 500 => 'The grid had a problem ($statusCode) — try again shortly.',
    _ => 'The grid answered $statusCode.',
  };
}

/// The gateway's error line: `{"detail": "…"}`.
///
/// Written for a person to read, so it is shown as-is. Null when the body is
/// not JSON or has no detail, and the caller falls back to the status code.
String? parseDetail(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final detail = decoded['detail'];
  return detail is String && detail.isNotEmpty ? detail : null;
}

/// A `-pat` row: the hand-pasted-token twin of a connector the app can sign
/// A connector that can only be set up by pasting a token in by hand.
///
/// There is no flow here for these: the app drives OAuth and nothing else, so a
/// `pat` row can only ever render as a line explaining that it isn't available.
/// The gateway lists several (`github`, `gmail`, `gmail-pat`, `figma-api`), and
/// on a screen whose whole purpose is a Connect button they are noise.
///
/// Dropped at the parse boundary so nothing downstream carries the rule. This
/// supersedes the earlier code-suffix match (`-pat`), which caught only the
/// twins and left `gmail` — itself `auth_type: pat` — sitting there unusable.
///
/// The cost is worth naming: when a connector gains OAuth support at the
/// backend, its row appears here on its own, and until then the app looks like
/// it has never heard of it. That is the intended reading — a connector the app
/// cannot set up is not on offer.
bool isManualAuthType(Object? authType) => authType == 'pat';

/// Reads `GET /v1/grid/connectors`.
///
/// Null means "not a catalog response at all", so the caller can fall back to
/// the bundled asset rather than blanking the screen. An empty list is a valid
/// answer and comes back as `[]`.
List<ConnectorCatalogEntry>? parseGatewayConnectors(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final list = decoded['connectors'];
  if (list is! List) return null;

  final entries = <ConnectorCatalogEntry>[];
  for (final entry in list) {
    if (entry is! Map<String, dynamic>) continue;
    final code = entry['code'];
    if (code is! String || code.isEmpty) continue;
    if (isManualAuthType(entry['auth_type'])) continue;
    final label = entry['label'];
    entries.add(
      ConnectorCatalogEntry(
        id: code,
        code: code,
        // Left **empty** rather than defaulting to the code, so the catalog
        // provider can tell "the gateway named this" from "nobody did" and
        // derive a readable name for the second case. The screen never renders
        // this raw.
        //
        // A label equal to the code counts as nobody naming it. The gateway
        // sends `"label": "gmail"` for some rows, which is the slug echoed back
        // rather than a name a person would write, and taking it at face value
        // put `gmail` and `github` in a list beside `Google Calendar` and
        // `Supabase MCP remote`. Treating it as absent sends it down the same
        // derivation path as a missing one.
        label: label is String && label != code ? label : '',
        description: entry['description'] is String
            ? entry['description'] as String
            : '',
        imageUrl: entry['image_url'] is String
            ? entry['image_url'] as String
            : '',
        mcpUrl: entry['mcp_url'] is String ? entry['mcp_url'] as String : '',
        // Only the literal "app" can be driven from here. "pat" means the user
        // must paste a token by hand and there is no flow to call at all.
        authMethod: entry['auth_type'] == 'app'
            ? ConnectorAuthMethod.app
            : ConnectorAuthMethod.manual,
        mcpReady: entry['mcp_ready'] == true,
        linkedAtServer: entry['status'] == 'connected',
        accountName: entry['account_name'] is String
            ? entry['account_name'] as String
            : '',
        canRefresh: entry['refresh'] == true,
      ),
    );
  }
  return sortCatalog(entries);
}

/// Reads `POST /v1/grid/connectors/start`.
ConnectorAuthorization? parseAuthorization(
  String raw, {
  required String fallbackConnector,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  final url = decoded['authorize_url'];
  final pickup = decoded['pickup_code'];
  // Missing either one leaves nothing to do: no page to open, or no way to
  // collect the result once the user finishes.
  if (url is! String || url.isEmpty) return null;
  if (pickup is! String || pickup.isEmpty) return null;

  return ConnectorAuthorization(
    connector: decoded['connector'] is String
        ? decoded['connector'] as String
        : fallbackConnector,
    authorizeUrl: url,
    pickupCode: pickup,
    // Clamped: a server that says "poll every 0 seconds" would spin, and one
    // that says "every hour" would look broken.
    pollInterval: Duration(
      seconds: decoded['poll_interval'] is int
          ? (decoded['poll_interval'] as int).clamp(1, 60)
          : 2,
    ),
    expiresIn: Duration(
      seconds: decoded['expires_in'] is int
          ? (decoded['expires_in'] as int).clamp(30, 3600)
          : 600,
    ),
  );
}

/// Reads `POST /v1/grid/connectors/poll`.
///
/// Every outcome is HTTP 200 — the failures included — so `status` is the only
/// thing that says what happened.
ConnectorPollResult? parsePollResult(
  String raw, {
  required String fallbackConnector,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  final status = switch (decoded['status']) {
    'pending' => ConnectorPollStatus.pending,
    'ready' => ConnectorPollStatus.ready,
    'failed' => ConnectorPollStatus.failed,
    'expired' => ConnectorPollStatus.expired,
    'consumed' => ConnectorPollStatus.consumed,
    // An unknown status is no reason to keep polling forever, and it is
    // certainly not success.
    _ => null,
  };
  if (status == null) return null;

  final connector = decoded['connector'] is String
      ? decoded['connector'] as String
      : fallbackConnector;
  return ConnectorPollResult(
    status: status,
    connector: connector,
    error: decoded['error'] is String ? decoded['error'] as String : '',
    token: status == ConnectorPollStatus.ready
        ? tokenFromPayload(decoded, connector)
        : null,
  );
}

/// Reads `POST /v1/grid/connectors/refresh`.
ConnectorToken? parseTokenPayload(
  String raw, {
  required String fallbackConnector,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final connector = decoded['connector'] is String
      ? decoded['connector'] as String
      : fallbackConnector;
  return tokenFromPayload(decoded, connector);
}

/// Builds the stored token from a `ready` or `refresh` payload.
///
/// `mcp_entry` may legitimately be null — five connectors are OAuth-capable
/// with no MCP server behind them. The token is real and the account is linked;
/// there is simply nothing to hand the agent.
ConnectorToken? tokenFromPayload(
  Map<String, dynamic> payload,
  String connector,
) {
  final access = payload['access_token'];
  if (access is! String || access.isEmpty) return null;

  final expiresAt = payload['expires_at'];
  return ConnectorToken(
    connector: connector,
    accessToken: access,
    refreshToken: payload['refresh_token'] is String
        ? payload['refresh_token'] as String
        : null,
    expiresAt: expiresAt is int && expiresAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
        : null,
    scope: payload['scope'] is String ? payload['scope'] as String : '',
    tokenType: payload['token_type'] is String
        ? payload['token_type'] as String
        : 'Bearer',
    accountName: payload['account_name'] is String
        ? payload['account_name'] as String
        : '',
    mcpEntry: McpEntry.fromJson(payload['mcp_entry']),
    // Top level, not inside `mcp_entry._grid`: the same answer lives in both,
    // but the `_grid` copy vanishes with the entry — and a connector with no MCP
    // server (google_drive, gmail, google_calendar) still holds a one-hour token
    // that has to be renewed. Null when an older control plane omits it.
    canRefresh: payload['refresh'] is bool ? payload['refresh'] as bool : null,
  );
}

/// The gateway client for the signed-in session. Overridable in tests so no
/// suite ever reaches the network.
final connectorGatewayClientProvider = Provider<ConnectorGatewayClient>((ref) {
  return ConnectorGatewayClient(
    apiUrl: ref.watch(gridApiUrlProvider),
    sessionToken: ref.watch(sessionProvider).sessionToken,
  );
});
