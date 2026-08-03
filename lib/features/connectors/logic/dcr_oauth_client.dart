import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/connector_token.dart';
import 'dcr_client_store.dart';
import 'mcp_auth_probe.dart';

/// A PKCE pair (RFC 7636).
///
/// The verifier is the secret; the challenge is what travels in the authorize
/// URL. Only `S256` is ever produced — see [PkcePair.create].
class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;

  static const String method = 'S256';

  /// 43 characters of base64url randomness — the RFC's minimum, and enough that
  /// guessing is not a threat model.
  ///
  /// [Random.secure] rather than `Random()`: the verifier is the only thing
  /// standing between an intercepted authorization code and a token for a public
  /// client, and a predictable PRNG would hand that away.
  static PkcePair create() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final verifier = _base64Url(bytes);
    return PkcePair(
      verifier: verifier,
      challenge: _base64Url(_sha256(utf8.encode(verifier))),
    );
  }

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// A step of path A that didn't work, carrying a line safe to show the user.
class DcrOAuthError {
  const DcrOAuthError(this.message, {this.isCancel = false});

  final String message;

  /// The user chose Deny, or closed the tab. Not a failure to report loudly —
  /// changing your mind is not an error.
  final bool isCancel;

  @override
  String toString() => message;
}

/// The app as its own OAuth client, for servers that register clients on demand.
///
/// This is **path A**: no backend, no pre-registered app, no `client_secret`
/// shipped in the binary. The app discovers the authorization server, registers
/// itself (RFC 7591), and runs authorization-code + PKCE (RFC 7636) with a
/// loopback redirect (RFC 8252) — the same shape Claude Desktop uses when you
/// paste an arbitrary remote MCP URL into it.
///
/// **Why the app and not the agent.** Whoever performs the registration owns the
/// resulting credential. If Hermes registered its own client, Codex would need a
/// second consent for the same account and Claude Code a third. So the app
/// registers once, stores the token in the agent-neutral master store, and each
/// adapter projects it — the token half of rule 4, and exactly what D10 settled.
///
/// Measured against live servers on 2026-07-30, and two findings shape the code:
///
/// - **A registered client is not always public.** Notion and Linear issue no
///   secret and accept `token_endpoint_auth_method: none`. Supabase issues a
///   44-character secret and advertises only `client_secret_basic` /
///   `client_secret_post`. So the token call is built from what the server said,
///   never assumed.
/// - **`plain` is on offer and must be refused.** Notion and Supabase both list
///   `plain` among their `code_challenge_methods_supported`. Taking it would be
///   PKCE with the protection removed, for nothing gained.
class DcrOAuthClient {
  const DcrOAuthClient({
    required DcrClientStore store,
    this.timeout = const Duration(seconds: 20),
  }) : _store = store;

  final DcrClientStore _store;
  final Duration timeout;

  /// Register this app with the authorization server [probe] found, reusing a
  /// registration when one already fits.
  ///
  /// Reuse requires both the issuer *and* the redirect URI to match, and the
  /// reason is worth keeping: an earlier version matched on issuer alone and
  /// carried the new loopback port in, on the strength of RFC 8252 §7.3 asking
  /// servers to accept any port for a native client. Measured 2026-07-30, they
  /// need not — Achriom answers `invalid_redirect_uri` for a port it did not see
  /// at registration, and the sign-in dies in the browser before the user can
  /// react.
  ///
  /// Hence the stable port in `OAuthLoopbackListener.preferredPorts`, which makes
  /// this match succeed on every ordinary reconnect. When it fails — every
  /// preferred port busy, or a registration written before that change —
  /// re-registering is the only thing that can work, and costs one spare client
  /// entry at the provider rather than a connector that cannot be signed into.
  /// [redirectUris] are the spellings of the same loopback callback, in the
  /// order worth trying. The first that registers is the one stored, and every
  /// later step reads it back off the client — so authorize and the token
  /// exchange stay byte-identical to what was registered, whichever won.
  Future<(DcrClient?, DcrOAuthError?)> register(
    McpAuthProbeResult probe, {
    required List<String> redirectUris,
  }) async {
    if (!probe.canSelfRegister) {
      return (
        null,
        const DcrOAuthError(
          'This server needs an app registered with it in advance, which only '
          'the Grid backend can do.',
        ),
      );
    }
    // Refuse before anything is written: without S256 there is no safe way to
    // run this as a public client, and proceeding on `plain` would be a silent
    // downgrade.
    if (!probe.supportsS256) {
      return (
        null,
        const DcrOAuthError(
          "This server's sign-in does not support the security this app "
          'requires (PKCE S256).',
        ),
      );
    }

    if (redirectUris.isEmpty) {
      return (
        null,
        const DcrOAuthError('No local address to receive the sign-in.'),
      );
    }
    final existing = await _store.find(probe.issuer);
    // Reuse only when the stored registration was made for *this* redirect URI.
    //
    // The previous version reused on issuer alone and carried the new port in,
    // reasoning that RFC 8252 §7.3 asks servers to accept any loopback port.
    // Measured 2026-07-30: they don't have to, and Achriom doesn't — a
    // reconnect on a different port fails at the authorize step with
    // `invalid_redirect_uri`, before the user can do anything about it.
    //
    // So the port is stable now (`OAuthLoopbackListener.preferredPorts`) and
    // this match nearly always succeeds. When it doesn't — every preferred port
    // busy, or a registration made before this change — re-registering is the
    // only thing that can work, and it costs one extra client entry at the
    // provider rather than a sign-in that cannot complete.
    if (existing != null && redirectUris.contains(existing.redirectUri)) {
      return (existing, null);
    }

    DcrOAuthError? refusal;
    for (final redirectUri in redirectUris) {
      final (payload, error) = await _post(
        Uri.parse(probe.registrationEndpoint),
        body: {
          'client_name': 'Grid',
          'redirect_uris': [redirectUri],
          'grant_types': ['authorization_code', 'refresh_token'],
          'response_types': ['code'],
          // Ask to be public. A server that can honour it (Notion, Linear) then
          // issues no secret; one that cannot (Supabase) overrides us and
          // returns one, which is why the reply is read rather than the request
          // trusted.
          'token_endpoint_auth_method': 'none',
          'application_type': 'native',
        },
        failure: "Couldn't register with this server.",
        // Registration is unauthenticated by design (RFC 7591 §3.1 open
        // registration), which is what makes path A possible at all.
        json: true,
      );

      if (payload == null) {
        refusal = error;
        // Another spelling of the same address is only worth trying when the
        // address is what was refused. Measured 2026-07-31: CoinDesk answers
        // `redirect_uris must be absolute https URIs (http allowed only for
        // localhost)` to the IP form and accepts the `localhost` one.
        //
        // Narrow on purpose. Retrying every failure would send a second
        // registration at a server that is down, rate-limiting us, or refusing
        // open registration outright — and would replace its own clear message
        // with whatever the second attempt happened to say.
        final says = error?.message.toLowerCase() ?? '';
        if (!says.contains('redirect')) break;
        continue;
      }

      final clientId = payload['client_id'];
      if (clientId is! String || clientId.isEmpty) {
        return (
          null,
          const DcrOAuthError(
            'This server accepted the registration but returned no client id.',
          ),
        );
      }

      final secret = payload['client_secret'];
      final client = DcrClient(
        issuer: probe.issuer,
        clientId: clientId,
        clientSecret: secret is String && secret.isNotEmpty ? secret : null,
        // Trust the server's stated method, then fall back to what the presence
        // of a secret implies — some servers echo nothing here.
        authMethod: _authMethod(payload, probe, hasSecret: secret is String),
        authorizationEndpoint: probe.authorizationEndpoint,
        tokenEndpoint: probe.tokenEndpoint,
        // Whichever spelling the server took. Stored, so authorize and the
        // token exchange send that one back byte for byte (RFC 6749 §4.1.3)
        // rather than the one this app would have preferred.
        redirectUri: redirectUri,
        registeredAt: DateTime.now(),
      );

      try {
        await _store.save(client);
      } on Object catch (failure) {
        // The registration exists at the server but not here. Say so: silently
        // continuing would work once and then re-register on the next attempt.
        return (
          null,
          DcrOAuthError("Couldn't save the registration ($failure)."),
        );
      }
      return (client, null);
    }
    return (null, refusal);
  }

  /// The authorize URL to open in the system browser.
  ///
  /// `state` is minted here — path A has no gateway to mint it, so the app is
  /// also what verifies it when the callback lands.
  Uri authorizeUrl({
    required DcrClient client,
    required McpAuthProbeResult probe,
    required PkcePair pkce,
    required String state,
  }) {
    final base = Uri.parse(client.authorizationEndpoint);
    return base.replace(
      queryParameters: {
        // Merge rather than replace: an authorization_endpoint may legitimately
        // carry its own query (a tenant id), and dropping it would 404.
        ...base.queryParameters,
        'response_type': 'code',
        'client_id': client.clientId,
        'redirect_uri': client.redirectUri,
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': PkcePair.method,
        // RFC 8707. Ties the token to this MCP server so it can't be replayed
        // against another resource behind the same authorization server.
        if (probe.resource.isNotEmpty) 'resource': probe.resource,
        // Supabase publishes eleven scopes and rejects an authorize with none;
        // Notion publishes `default`. Sending what the resource itself declared
        // avoids hardcoding either.
        if (probe.scopesSupported.isNotEmpty)
          'scope': probe.scopesSupported.join(' '),
      },
    );
  }

  /// Swap the authorization code for a token.
  ///
  /// [connector] is the name the token is filed under in the master store, and
  /// the MCP server name it projects to.
  Future<(ConnectorToken?, DcrOAuthError?)> exchange({
    required DcrClient client,
    required McpAuthProbeResult probe,
    required PkcePair pkce,
    required String code,
    required String connector,
    required String mcpUrl,
  }) async {
    final (payload, error) = await _post(
      Uri.parse(client.tokenEndpoint),
      form: {
        'grant_type': 'authorization_code',
        'code': code,
        // Must match the authorize call exactly (RFC 6749 §4.1.3).
        'redirect_uri': client.redirectUri,
        'client_id': client.clientId,
        'code_verifier': pkce.verifier,
        if (probe.resource.isNotEmpty) 'resource': probe.resource,
        if (client.authMethod == 'client_secret_post' &&
            client.clientSecret != null)
          'client_secret': client.clientSecret!,
      },
      basicAuth: client.authMethod == 'client_secret_basic'
          ? (client.clientId, client.clientSecret ?? '')
          : null,
      failure: "Couldn't finish the sign-in.",
    );
    if (payload == null) return (null, error);
    return tokenFrom(
      payload,
      connector: connector,
      mcpUrl: mcpUrl,
      // Without this the stored token has no issuer, and `refresh` cannot find
      // the registration it needs — every DCR connector would report "that
      // connection expired" about an hour after signing in, with a perfectly
      // good refresh token sitting next to it. Verified against the two entries
      // this omission had already written on 2026-07-30.
      issuer: probe.issuer,
    );
  }

  /// Renew a path-A token using its refresh token.
  ///
  /// Path A refreshes **here**, not at the gateway: our backend never saw this
  /// credential and has no way to mint a replacement. This is why
  /// `ConnectorToken.source` exists — calling the gateway's `/refresh` for one of
  /// these would ask it about a connector it has never heard of.
  Future<(ConnectorToken?, DcrOAuthError?)> refresh(
    ConnectorToken token, {
    required String issuer,
  }) async {
    final refreshToken = token.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      return (
        null,
        const DcrOAuthError('This connection cannot be renewed automatically.'),
      );
    }
    final client = await _store.find(issuer);
    if (client == null) {
      return (
        null,
        const DcrOAuthError(
          'The registration for this server is missing. Connect it again.',
        ),
      );
    }

    final (payload, error) = await _post(
      Uri.parse(client.tokenEndpoint),
      form: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': client.clientId,
        if (client.authMethod == 'client_secret_post' &&
            client.clientSecret != null)
          'client_secret': client.clientSecret!,
      },
      basicAuth: client.authMethod == 'client_secret_basic'
          ? (client.clientId, client.clientSecret ?? '')
          : null,
      failure: "Couldn't refresh the connection.",
    );
    if (payload == null) return (null, error);

    final url = token.mcpEntry?.url ?? '';
    final (renewed, parseError) = tokenFrom(
      payload,
      connector: token.connector,
      mcpUrl: url,
      issuer: issuer,
    );
    if (renewed == null) return (null, parseError);
    return (
      // A refresh response may omit `refresh_token`, meaning "keep using the one
      // you have" (RFC 6749 §6). Dropping it here would make the next renewal
      // impossible.
      renewed.refreshToken == null
          ? renewed.copyWith(refreshToken: refreshToken)
          : renewed,
      null,
    );
  }

  /// Build the stored token from a token-endpoint response.
  ///
  /// The `mcp_entry` is rendered **here**, because on path A there is no server
  /// to render it. It is the same shape the gateway produces, so everything
  /// downstream — the master store, every agent projection, the refresh sweep —
  /// cannot tell the two paths apart.
  @visibleForTesting
  (ConnectorToken?, DcrOAuthError?) tokenFrom(
    Map<String, dynamic> payload, {
    required String connector,
    required String mcpUrl,
    String issuer = '',
  }) {
    final access = payload['access_token'];
    if (access is! String || access.isEmpty) {
      return (
        null,
        const DcrOAuthError('The server returned no access token.'),
      );
    }
    final type = payload['token_type'] is String
        ? payload['token_type'] as String
        : 'Bearer';
    final expiresIn = payload['expires_in'];
    final expiresAt = expiresIn is num && expiresIn > 0
        ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
        : null;
    final refreshToken = payload['refresh_token'];
    // On path A there is no gateway to answer "can this be renewed", and the
    // provider's own reply is the whole answer: a `refresh_token` came back, or
    // it did not. Recorded at the top level as well as inside `mcp_entry`,
    // because the entry is optional — a connector with no MCP server still
    // holds an expiring credential — and because a store where gateway entries
    // carry `"refresh": true` and self-registered ones carry nothing invites
    // the reader to conclude the second kind does not renew.
    final renewable = refreshToken is String && refreshToken.isNotEmpty;

    return (
      ConnectorToken(
        connector: connector,
        accessToken: access,
        refreshToken: renewable ? refreshToken : null,
        expiresAt: expiresAt,
        scope: payload['scope'] is String ? payload['scope'] as String : '',
        tokenType: type,
        mcpEntry: mcpUrl.isEmpty
            ? null
            : McpEntry(
                url: mcpUrl,
                // Every server measured declared `bearer_methods_supported:
                // ["header"]`, which is the only method this renders. A server
                // wanting the token elsewhere would need its own case, and would
                // be caught by the probe rather than guessed at here.
                headers: {'Authorization': '$type $access'},
                expiresAt: expiresAt,
                canRefresh: renewable,
              ),
        canRefresh: renewable,
        source: ConnectorTokenSource.dcr,
        issuer: issuer,
      ),
      null,
    );
  }

  /// What the token call should use, in order of authority: the server's echoed
  /// method, then whether it gave us a secret at all.
  String _authMethod(
    Map<String, dynamic> payload,
    McpAuthProbeResult probe, {
    required bool hasSecret,
  }) {
    final stated = payload['token_endpoint_auth_method'];
    if (stated is String && stated.isNotEmpty) return stated;
    if (!hasSecret) return 'none';
    // It handed us a secret without saying how to use it. Prefer whichever of
    // the two it advertised, `_post` being the more widely accepted.
    if (probe.tokenAuthMethods.contains('client_secret_post')) {
      return 'client_secret_post';
    }
    if (probe.tokenAuthMethods.contains('client_secret_basic')) {
      return 'client_secret_basic';
    }
    return 'client_secret_post';
  }

  /// One POST, JSON or form-encoded, returning a decoded object or an error line.
  ///
  /// OAuth errors arrive as `{"error": "...", "error_description": "..."}` with a
  /// 4xx status (RFC 6749 §5.2). The description is written for a developer, not
  /// a user, so it is shown only as the tail of our own sentence.
  Future<(Map<String, dynamic>?, DcrOAuthError?)> _post(
    Uri url, {
    Map<String, Object?>? body,
    Map<String, String>? form,
    (String, String)? basicAuth,
    required String failure,
    bool json = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (basicAuth != null) {
        final encoded = base64Encode(
          utf8.encode('${basicAuth.$1}:${basicAuth.$2}'),
        );
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $encoded');
      }
      if (form != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.write(
          form.entries
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent(e.key)}='
                    '${Uri.encodeQueryComponent(e.value)}',
              )
              .join('&'),
        );
      } else {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body ?? const {}));
      }

      final response = await request.close().timeout(timeout);
      final raw = await response.transform(utf8.decoder).join();
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return (
          null,
          DcrOAuthError('$failure The server answered $raw'.trim()),
        );
      }
      if (decoded is! Map<String, dynamic>) {
        return (null, DcrOAuthError(failure));
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded['error'];
        final description = decoded['error_description'];
        final tail = description is String && description.isNotEmpty
            ? description
            : (code is String && code.isNotEmpty
                  ? code
                  : 'It answered ${response.statusCode}.');
        return (null, DcrOAuthError('$failure $tail'));
      }
      return (decoded, null);
    } on Object catch (error) {
      return (null, DcrOAuthError("$failure Couldn't reach it: $error"));
    } finally {
      client.close(force: true);
    }
  }
}

/// The `S256` challenge for [verifier].
///
/// Exposed so the hand-rolled hash below can be pinned to the RFC 7636
/// appendix-B vector (`test/connectors/pkce_test.dart`). A wrong hash would fail
/// only at the authorization server, as an unexplained "sign-in didn't work" —
/// so this is the one part of path A that is worth a test on its own.
String challengeFor(String verifier) =>
    PkcePair._base64Url(_sha256(utf8.encode(verifier)));

/// A URL-safe random string, used for `state`.
String randomStateValue() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// SHA-256, so PKCE needs no package dependency.
///
/// Written out rather than pulled from `package:crypto` for one reason: this is
/// the only hash the app needs, and a dependency added for 60 lines is a
/// dependency to keep updated forever. Verified against the RFC 7636 appendix-B
/// test vector in `test/connectors/pkce_test.dart` — a hand-rolled hash that
/// isn't pinned to a known vector is a liability, not a saving.
List<int> _sha256(List<int> message) {
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  // Pad: 0x80, zeros, then the 64-bit big-endian bit length.
  final padded = <int>[...message, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bitLength = message.length * 8;
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (i * 8)) & 0xff);
  }

  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final o = chunk + i * 4;
      w[i] =
          (padded[o] << 24) |
          (padded[o + 1] << 16) |
          (padded[o + 2] << 8) |
          padded[o + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];

    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = (hh + s1 + ch + k[i] + w[i]) & 0xffffffff;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }

  return [
    for (final value in h) ...[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ],
  ];
}

final dcrOAuthClientProvider = Provider<DcrOAuthClient>(
  (ref) => DcrOAuthClient(store: ref.watch(dcrClientStoreProvider)),
);
