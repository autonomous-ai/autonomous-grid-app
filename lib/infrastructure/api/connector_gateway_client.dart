import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/logic/session_controller.dart';
import '../../features/connectors/logic/connector_link_status.dart';
import '../providers.dart';

/// A gateway call that didn't work. [message] is the line a button can show.
class ConnectorGatewayError {
  const ConnectorGatewayError(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() => message;
}

/// Where the browser should be sent, plus the handle the gateway will hand
/// back through the loopback callback.
class AuthorizeGrant {
  const AuthorizeGrant({required this.authorizeUrl, this.authType = ''});

  final String authorizeUrl;

  /// The gateway's own word for the flow it started (`oauth`, `pat`, …).
  /// Carried but not interpreted: the app opens a browser either way, and
  /// guessing at values we haven't seen would be inventing a contract.
  final String authType;
}

/// One connector's state on this device, from the gateway's per-device list.
class DeviceConnector {
  const DeviceConnector({
    required this.code,
    required this.status,
    this.errorMessage = '',
  });

  /// The catalog `code` — the join key against the catalog and the config.
  final String code;

  final ConnectorLinkStatus status;

  /// Why the last attempt failed, when [status] is
  /// [ConnectorLinkStatus.connectFailed]. The row shows it in a tooltip rather
  /// than a toast: it's a property of the row, not an event.
  final String errorMessage;
}

/// The OAuth gateway the web's Connectors tab already uses, seen from the
/// desktop app.
///
/// The gateway is a **smart** server and this is a deliberately **dumb**
/// client: the backend mints `state`, holds every provider's `client_id` and
/// `client_secret`, performs the code-for-token exchange, and stores the result
/// encrypted. What comes back to us through the loopback callback is a gateway
/// session handle, never a provider credential. Adding a provider is a row in
/// the backend's config table and *no* app change at all — which is the whole
/// reason to adopt this rather than build a second gateway.
///
/// Every method returns `(value, error)` and never throws: each one is behind a
/// button, and a button needs a line to show rather than an exception to
/// swallow.
class ConnectorGatewayClient {
  const ConnectorGatewayClient({
    required this.apiUrl,
    required this.sessionToken,
    this.timeout = const Duration(seconds: 20),
  });

  final String apiUrl;

  /// Null or empty when signed out. Every gateway call needs a user session —
  /// the connector is being linked to an account, not to a machine.
  final String? sessionToken;

  final Duration timeout;

  static Uri endpoint(String apiUrl, String path) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    return Uri.parse('$base$path');
  }

  /// Ask the gateway to start a link. [redirectUri] is this app's loopback
  /// listener, already bound — the port is known before this call, so nothing
  /// here has to guess it.
  Future<(AuthorizeGrant?, ConnectorGatewayError?)> authorize({
    required String connector,
    required String deviceId,
    required String deviceType,
    required String redirectUri,
  }) async {
    return _send(
      'POST',
      'v1/connectors/authorize',
      body: {
        'connector': connector,
        'device_id': deviceId,
        'device_type': deviceType,
        'redirect_uri': redirectUri,
      },
      parse: parseAuthorizeGrant,
      failure: "Couldn't start the sign-in.",
    );
  }

  /// Finalize a link with the handles the loopback callback received.
  ///
  /// This is where `state` is actually checked. The app can't validate it
  /// itself — the gateway minted it and never showed it to us — so whatever
  /// arrived at the listener is a *candidate* until this call accepts it. That
  /// makes the server's verdict the security boundary, which is the right place
  /// for it: single-use, bound to the device and user, and expiring on its own.
  Future<(bool, ConnectorGatewayError?)> finalizeCallback({
    required String code,
    required String state,
  }) async {
    final (ok, error) = await _send<bool>(
      'POST',
      'v1/connectors/oauth/callback',
      body: {'code': code, 'state': state},
      parse: (_) => true,
      failure: "Couldn't finish the sign-in.",
    );
    return (ok ?? false, error);
  }

  /// Every connector's state on this device — the poll that moves a row from
  /// "Connecting…" to "Connected".
  Future<(List<DeviceConnector>?, ConnectorGatewayError?)> deviceConnectors(
    String deviceId,
  ) {
    return _send(
      'GET',
      'device/$deviceId/connectors',
      parse: parseDeviceConnectors,
      failure: "Couldn't read the connectors for this computer.",
    );
  }

  /// Unlink at the backend. The app still has to clear its own token and
  /// re-project afterwards — this only ends the account link.
  Future<(bool, ConnectorGatewayError?)> disconnect({
    required String connector,
    required String deviceId,
    required String deviceType,
  }) async {
    final (ok, error) = await _send<bool>(
      'POST',
      'v1/connectors/disconnect',
      body: {
        'connector': connector,
        'device_id': deviceId,
        'device_type': deviceType,
      },
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

      // The envelope carries its own verdict, so a 200 with `status != 1` is
      // still a failure — and its `error_message` is the only text worth
      // showing. Checking the HTTP code alone would report "signed in" for a
      // body that says the state expired.
      final message = parseEnvelopeError(raw);
      if (message != null) {
        return (
          null,
          ConnectorGatewayError(
            message,
            statusCode: response.statusCode,
            body: raw,
          ),
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (
          null,
          ConnectorGatewayError(
            failure,
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

/// The business-error line inside the envelope, or null when the body doesn't
/// claim a failure.
///
/// The gateway reports business failures as HTTP 200 with `status != 1` and an
/// `error_message` — an expired `state`, a connector already linked. The
/// message is the useful part and the status code isn't, so it's read first and
/// preferred over any generic line the caller would otherwise show.
///
/// A body that isn't JSON reads as "no claim" rather than as an error: the
/// caller still has the HTTP status to fall back on.
String? parseEnvelopeError(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final status = decoded['status'];
  if (status is! int || status == 1) return null;

  for (final key in ['error_message', 'message', 'system_message']) {
    final value = decoded[key];
    if (value is String && value.isNotEmpty) return value;
  }
  final data = decoded['data'];
  if (data is Map<String, dynamic> && data['error_message'] is String) {
    final value = data['error_message'] as String;
    if (value.isNotEmpty) return value;
  }
  return 'The grid refused the request.';
}

/// Reads `{"status": 1, "data": {"authorize_url": "…", "auth_type": "oauth"}}`.
///
/// Null when there's no usable URL — the caller shows "couldn't start" rather
/// than opening a browser at nothing.
AuthorizeGrant? parseAuthorizeGrant(String raw) {
  final data = _envelopeData(raw);
  if (data is! Map<String, dynamic>) return null;
  final url = data['authorize_url'];
  if (url is! String || url.isEmpty) return null;
  return AuthorizeGrant(
    authorizeUrl: url,
    authType: data['auth_type'] is String ? data['auth_type'] as String : '',
  );
}

/// Reads the per-device connector list.
///
/// Lenient per row, like every other list parser here: an entry missing its
/// `code` is dropped and the rest still show. Null only when the response isn't
/// a list at all, so the caller can tell "nothing linked" (`[]`) from "couldn't
/// read that" — the two mean different things to a screen.
List<DeviceConnector>? parseDeviceConnectors(String raw) {
  final data = _envelopeData(raw);
  final list = data is Map<String, dynamic> ? data['connectors'] : data;
  if (list is! List) return null;

  final connectors = <DeviceConnector>[];
  for (final entry in list) {
    if (entry is! Map<String, dynamic>) continue;
    final code = entry['code'] ?? entry['connector'];
    if (code is! String || code.isEmpty) continue;
    connectors.add(
      DeviceConnector(
        code: code,
        status: parseConnectorLinkStatus(entry['status']),
        errorMessage: entry['error'] is String
            ? entry['error'] as String
            : entry['error_message'] is String
            ? entry['error_message'] as String
            : '',
      ),
    );
  }
  return connectors;
}

Object? _envelopeData(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  return decoded['data'];
}

/// The gateway client for the signed-in session. Overridable in tests so no
/// suite ever reaches the network.
final connectorGatewayClientProvider = Provider<ConnectorGatewayClient>((ref) {
  return ConnectorGatewayClient(
    apiUrl: ref.watch(gridApiUrlProvider),
    sessionToken: ref.watch(sessionProvider).sessionToken,
  );
});
