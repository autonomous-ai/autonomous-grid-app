import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How an MCP server expects to be authenticated, discovered by asking it.
///
/// This is the runtime split between the two OAuth paths — the one the catalog's
/// `auth_type` decides for *listed* connectors, worked out from scratch for a URL
/// the user typed. Nothing here is guessed from the hostname.
enum McpAuthKind {
  /// No credential needed: the server answered without a challenge.
  open,

  /// OAuth, and the authorization server registers clients on demand
  /// (RFC 7591). The app can obtain a `client_id` itself, so this connects with
  /// no backend involvement at all.
  dynamicRegistration,

  /// OAuth, but clients must be pre-registered by hand — no
  /// `registration_endpoint`. Google and Slack are here. Only the gateway can
  /// drive these, because only it can hold the `client_secret`.
  preRegistered,

  /// The server wants a credential the app can't negotiate — it challenged with
  /// something other than Bearer, or its metadata is unreadable. The user has to
  /// paste a token by hand.
  manual,

  /// Nothing answered at this URL: DNS, TLS, a timeout, or an HTTP status that
  /// is not an MCP endpoint at all.
  ///
  /// Kept apart from [open] because the two used to be one, and conflating them
  /// is how an unreachable host came to read as "needs no sign-in" — an
  /// encouraging sentence about a server that does not exist.
  unreachable,
}

/// What one probe learned about a server.
class McpAuthProbeResult {
  const McpAuthProbeResult({
    required this.kind,
    this.issuer = '',
    this.authorizationEndpoint = '',
    this.tokenEndpoint = '',
    this.registrationEndpoint = '',
    this.scopesSupported = const [],
    this.resource = '',
    this.supportsS256 = false,
    this.tokenAuthMethods = const [],
    this.detail = '',
  });

  final McpAuthKind kind;

  /// The authorization server's own identifier, and the key registrations are
  /// stored under.
  ///
  /// Deliberately *not* the MCP URL. Supabase makes the reason concrete: the
  /// resource is `mcp.supabase.com` while the authorization server is
  /// `api.supabase.com`. Two MCP servers behind one authorization server share a
  /// registration, and keying on the resource would register twice.
  final String issuer;

  final String authorizationEndpoint;
  final String tokenEndpoint;

  /// Empty unless [kind] is [McpAuthKind.dynamicRegistration].
  final String registrationEndpoint;

  /// What the resource says it can grant. Sent verbatim on the authorize call —
  /// Supabase publishes eleven and rejects an authorize with none.
  final List<String> scopesSupported;

  /// The `resource` identifier from the protected-resource metadata, for the
  /// RFC 8707 `resource` parameter.
  final String resource;

  /// The authorization server advertises PKCE `S256`.
  ///
  /// Tracked because the app refuses to proceed without it. Two of the three
  /// servers measured also offer `plain`, which is PKCE with the protection
  /// removed; accepting it merely because it is offered would be a downgrade
  /// with nothing gained.
  final bool supportsS256;

  /// `token_endpoint_auth_methods_supported`. Decides whether the token call
  /// carries client credentials — see `DcrClient.authMethod`.
  final List<String> tokenAuthMethods;

  /// Why, when [kind] is [McpAuthKind.manual] — a line worth showing.
  final String detail;

  bool get canSelfRegister => kind == McpAuthKind.dynamicRegistration;
}

/// Asks an MCP server how to authenticate against it.
///
/// The three-step discovery of MCP's authorization spec, which is RFC 9728 plus
/// RFC 8414:
///
/// ```
/// 1  POST <url>                                  → 401 + WWW-Authenticate:
///                                                  Bearer resource_metadata="…"
/// 2  GET  <resource_metadata>                    → authorization_servers: [ … ]
/// 3  GET  <as>/.well-known/oauth-authorization-server
///                                                → registration_endpoint?
/// ```
///
/// Verified against live servers on 2026-07-30, and the results are why the
/// steps are written this way rather than shortcut:
///
/// | server | step 1 | AS issuer | registration | secret issued |
/// |---|---|---|---|---|
/// | `mcp.notion.com`   | 401 | `mcp.notion.com`   | `/register` | no |
/// | `mcp.linear.app`   | 401 | `mcp.linear.app`   | `/register` | no |
/// | `mcp.supabase.com` | 401 | **`api.supabase.com`** | `/platform/oauth/apps/register` | **yes** |
///
/// Supabase is the case that shapes the code: its authorization server is on a
/// different host from its MCP endpoint, so step 2 cannot be skipped by assuming
/// the resource is its own issuer.
class McpAuthProbe {
  const McpAuthProbe({this.timeout = const Duration(seconds: 12)});

  final Duration timeout;

  /// Probe [url]. Never throws — every failure becomes a result, because the one
  /// caller is a dialog that has to say something either way.
  Future<McpAuthProbeResult> probe(String url) async {
    final target = Uri.tryParse(url.trim());
    if (target == null || !target.hasScheme || !target.hasAuthority) {
      return const McpAuthProbeResult(
        kind: McpAuthKind.manual,
        detail: "That doesn't look like a URL.",
      );
    }

    final challenge = await _challenge(target);
    // Nothing answered. Reported as its own state so the screen can say "we
    // couldn't reach it" rather than the far more encouraging — and wrong —
    // "this server needs no sign-in".
    if (challenge is _Unreachable) {
      return McpAuthProbeResult(
        kind: McpAuthKind.unreachable,
        detail: challenge.detail,
      );
    }
    // It answered, and it answered without asking for anything. Usable as-is.
    if (challenge == null) {
      return const McpAuthProbeResult(kind: McpAuthKind.open);
    }
    if (challenge.isEmpty) {
      return const McpAuthProbeResult(
        kind: McpAuthKind.manual,
        detail:
            'This server asks for a credential but does not say how to get '
            'one. You will need to paste a token.',
      );
    }

    // RFC 9728 says the challenge names its metadata document. Falling back to
    // the well-known path on the resource's own origin covers servers that
    // challenge without the hint.
    final metadataUrl =
        challenge.resourceMetadata ??
        target.replace(
          path: '/.well-known/oauth-protected-resource',
          query: '',
        );

    final resourceMeta = await _json(metadataUrl);
    final servers = resourceMeta?['authorization_servers'];
    final asBase = servers is List && servers.isNotEmpty
        ? Uri.tryParse('${servers.first}')
        : null;
    if (asBase == null) {
      return const McpAuthProbeResult(
        kind: McpAuthKind.manual,
        detail:
            "This server's sign-in details could not be read. You will "
            'need to paste a token.',
      );
    }

    final scopes = <String>[
      for (final scope in (resourceMeta?['scopes_supported'] as List? ?? []))
        if (scope is String) scope,
    ];
    final resource = resourceMeta?['resource'] is String
        ? resourceMeta!['resource'] as String
        : target.toString();

    final asMeta = await _authServerMetadata(asBase);
    if (asMeta == null) {
      return McpAuthProbeResult(
        kind: McpAuthKind.manual,
        issuer: asBase.toString(),
        detail:
            'The sign-in service at ${asBase.host} did not describe itself. '
            'You will need to paste a token.',
      );
    }

    String field(String key) =>
        asMeta[key] is String ? asMeta[key] as String : '';
    final methods = <String>[
      for (final m
          in (asMeta['token_endpoint_auth_methods_supported'] as List? ?? []))
        if (m is String) m,
    ];
    final challengeMethods = <String>[
      for (final m
          in (asMeta['code_challenge_methods_supported'] as List? ?? []))
        if (m is String) m,
    ];

    final authorize = field('authorization_endpoint');
    final token = field('token_endpoint');
    final register = field('registration_endpoint');
    // Without these two there is nothing to drive, registration or not.
    if (authorize.isEmpty || token.isEmpty) {
      return McpAuthProbeResult(
        kind: McpAuthKind.manual,
        issuer: field('issuer').isEmpty ? asBase.toString() : field('issuer'),
        detail:
            'The sign-in service at ${asBase.host} is missing endpoints '
            'this app needs. You will need to paste a token.',
      );
    }

    return McpAuthProbeResult(
      kind: register.isEmpty
          ? McpAuthKind.preRegistered
          : McpAuthKind.dynamicRegistration,
      // Prefer the server's own `issuer` over the URL we reached it at: they can
      // differ, and the issuer is what the registration is keyed by.
      issuer: field('issuer').isEmpty ? asBase.toString() : field('issuer'),
      authorizationEndpoint: authorize,
      tokenEndpoint: token,
      registrationEndpoint: register,
      scopesSupported: scopes,
      resource: resource,
      supportsS256: challengeMethods.contains('S256'),
      tokenAuthMethods: methods,
    );
  }

  /// Step 1: make an unauthenticated call and read the challenge.
  ///
  /// Uses a real `initialize` request rather than a bare GET: a streamable-HTTP
  /// MCP endpoint answers `405` to GET, which says nothing about auth.
  ///
  /// Three outcomes, and keeping them apart is the whole point:
  ///
  /// - `null` — it answered and asked for nothing (`open`).
  /// - a [_Challenge] — it asked for something, parseable or not.
  /// - an [_Unreachable] — nothing answered at all.
  Future<_Challenge?> _challenge(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/event-stream',
      );
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-06-18',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'Grid', 'version': '1'},
          },
        }),
      );
      final response = await request.close().timeout(timeout);
      // Drain regardless — an unread response holds the socket open.
      await response.drain<void>();

      final status = response.statusCode;
      if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
        final header =
            response.headers.value(HttpHeaders.wwwAuthenticateHeader) ?? '';
        return _Challenge.parse(header);
      }
      // A 2xx means a live MCP endpoint that wants nothing. Anything else is a
      // web server answering, but not an MCP one — a 404 on a mistyped path, a
      // 500, a login page. Calling that "needs no sign-in" would send the user
      // on to Connect against a URL that will never work.
      if (status >= 200 && status < 300) return null;
      return _Unreachable(
        status == HttpStatus.notFound
            ? 'Nothing is published at that URL (404). Check the address.'
            : 'That address answered $status, which is not an MCP server.',
      );
    } on Object catch (error) {
      return _Unreachable(_reachabilityMessage(error));
    } finally {
      client.close(force: true);
    }
  }

  /// Step 3, both spellings.
  ///
  /// RFC 8414 puts the document at `/.well-known/oauth-authorization-server`;
  /// some servers only publish the OpenID one. Linear serves both, Notion and
  /// Supabase only the first — so try that first and fall back.
  Future<Map<String, dynamic>?> _authServerMetadata(Uri base) async {
    for (final path in const [
      '.well-known/oauth-authorization-server',
      '.well-known/openid-configuration',
    ]) {
      // Preserve any path on the issuer (`https://host/tenant`) as RFC 8414 §3.1
      // requires: the well-known segment is inserted, not appended.
      final candidate = base.replace(
        path: base.path.isEmpty || base.path == '/'
            ? '/$path'
            : '${base.path.replaceAll(RegExp(r'/$'), '')}/$path',
      );
      final json = await _json(candidate);
      if (json != null) return json;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _json(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return null;
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Nothing answered at the URL.
///
/// Modelled as a [_Challenge] subtype so the "did it ask for anything" contract
/// stays a single nullable return, while still carrying a sentence explaining
/// what went wrong. [isEmpty] is true for the same reason it is on a malformed
/// challenge: there is nothing here to drive.
class _Unreachable extends _Challenge {
  const _Unreachable(this.detail) : super(resourceMetadata: null, scheme: '');

  /// A line written for the person looking at the dialog, not for a log.
  final String detail;
}

/// Turn a socket-level failure into something a person can act on.
///
/// The raw exception is unhelpful at best (`SocketException: Failed host
/// lookup`) and alarming at worst (a TLS chain dump). Each case here suggests
/// the fix that actually applies.
String _reachabilityMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (error is TimeoutException || text.contains('timeout')) {
    return "That server didn't answer in time. It may be slow or offline.";
  }
  if (text.contains('failed host lookup') || text.contains('nodename')) {
    return "That address doesn't resolve. Check the spelling.";
  }
  if (text.contains('certificate') || text.contains('handshake')) {
    return "That server's security certificate could not be verified.";
  }
  if (text.contains('connection refused') || text.contains('errno = 61')) {
    return 'Nothing is listening at that address.';
  }
  return "That server could not be reached.";
}

/// A parsed `WWW-Authenticate` header.
class _Challenge {
  const _Challenge({required this.resourceMetadata, required this.scheme});

  final Uri? resourceMetadata;
  final String scheme;

  /// True when there is nothing here the app can act on.
  bool get isEmpty => scheme.toLowerCase() != 'bearer';

  /// Reads `Bearer realm="…", resource_metadata="https://…"`.
  ///
  /// Hand-parsed rather than split on commas: the `error_description` values
  /// measured in the wild contain commas inside their quotes ("No access token
  /// was provided in this request" is fine, but Supabase's full header is a
  /// three-parameter list), so a naive split loses the parameter that matters.
  static _Challenge parse(String header) {
    final trimmed = header.trim();
    if (trimmed.isEmpty) {
      return const _Challenge(resourceMetadata: null, scheme: '');
    }
    final space = trimmed.indexOf(' ');
    final scheme = space < 0 ? trimmed : trimmed.substring(0, space);

    final match = RegExp(
      r'resource_metadata\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(trimmed);
    return _Challenge(
      resourceMetadata: match == null ? null : Uri.tryParse(match.group(1)!),
      scheme: scheme,
    );
  }
}

/// Overridable so tests and the dialog share one probe, and no suite reaches the
/// network by accident.
final mcpAuthProbeProvider = Provider<McpAuthProbe>(
  (ref) => const McpAuthProbe(),
);
