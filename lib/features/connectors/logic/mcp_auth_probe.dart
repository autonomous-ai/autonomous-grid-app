import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// | `mcp.stripe.com`   | 401 | **`access.stripe.com/mcp`** | `/mcp/oauth2/register` | no |
///
/// Two of them shape the code. **Supabase**: its authorization server is on a
/// different host from its MCP endpoint, so step 2 cannot be skipped by
/// assuming the resource is its own issuer. **Stripe**: its issuer carries a
/// *path*, which decides where the well-known segment goes in step 3 — see
/// [McpAuthProbe.metadataCandidates], and note that Stripe also sends its
/// `resource_metadata` unquoted and publishes its scopes on the authorization
/// server rather than the resource. One connector, three assumptions broken.
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
    // It answered without asking for anything — which is not the end of the
    // question, and treating it as one is the bug this flag exists to stop.
    //
    // **A server can serve anonymous callers and still offer a sign-in.**
    // Hugging Face does: `initialize` returns 200 to a client with no
    // credential (rate-limited), and it publishes a full protected-resource
    // document with `registration_endpoint` and S256 beside it. Stopping at the
    // 200 called that `open`, so the app filed the connector with no credential
    // and left the user anonymous on an account they could have signed into —
    // and Hugging Face then served its *web page* to the agent's SSE GET, which
    // is what a browser gets at that URL and what an unauthenticated client
    // therefore got too. With a credential the same GET answers `405`, exactly
    // like every other MCP server.
    //
    // Claude asks for the metadata regardless of the challenge, which is why
    // its Hugging Face row opens a consent screen and ours did not.
    //
    // So discovery now runs either way, and `open` is the answer only when
    // discovery turns up nothing — see [noSignIn].
    final anonymousWorks = challenge == null;
    if (!anonymousWorks && challenge.isEmpty) {
      return const McpAuthProbeResult(
        kind: McpAuthKind.manual,
        detail:
            'This server asks for a credential but does not say how to get '
            'one. You will need to paste a token.',
      );
    }

    /// What a dead end in discovery means — which depends entirely on whether
    /// the server let us in without one.
    ///
    /// The same missing document is "this needs no sign-in" for a server that
    /// answered 200 and "we could not work out how to sign in" for one that
    /// refused us. Getting this backwards is the whole risk of the change
    /// above: reporting a refusing server as `open` files a connector whose
    /// every call then fails (the BigQuery shape), and reporting an open one as
    /// `manual` takes the Connect button off a row that works today.
    McpAuthProbeResult noSignIn(String detail) => anonymousWorks
        ? const McpAuthProbeResult(kind: McpAuthKind.open)
        : McpAuthProbeResult(kind: McpAuthKind.manual, detail: detail);

    // RFC 9728 §3.1 says the challenge names its metadata document. Where it
    // doesn't — which now includes every server that never challenged at all —
    // the URL is derived from the resource the same way RFC 8414 derives the
    // authorization server's, and for the same reason: the segment is inserted
    // before the path, not appended. See [resourceMetadataCandidates].
    Map<String, dynamic>? resourceMeta;
    for (final candidate in [
      ?challenge?.resourceMetadata,
      ...resourceMetadataCandidates(target),
    ]) {
      resourceMeta = await _json(candidate);
      if (resourceMeta != null) break;
    }

    final servers = resourceMeta?['authorization_servers'];
    final asBase = servers is List && servers.isNotEmpty
        ? Uri.tryParse('${servers.first}')
        : null;
    if (asBase == null) {
      return noSignIn(
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
      return noSignIn(
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
    // The authorization server's own scope list, used only when the resource
    // published none.
    //
    // RFC 9728 puts `scopes_supported` on the resource, and that stays the
    // better answer where it exists: it says what *this* resource grants, while
    // the authorization server speaks for everything behind it. But Stripe's
    // protected-resource document carries nothing but `resource` and
    // `authorization_servers`, and declares `["mcp"]` on the authorization
    // server instead — so reading only the first sends an authorize with no
    // `scope` at all. Supabase is the standing proof that some servers reject
    // exactly that.
    final asScopes = <String>[
      for (final scope in (asMeta['scopes_supported'] as List? ?? []))
        if (scope is String) scope,
    ];

    final authorize = field('authorization_endpoint');
    final token = field('token_endpoint');
    final register = field('registration_endpoint');
    // Without these two there is nothing to drive, registration or not.
    if (authorize.isEmpty || token.isEmpty) {
      return noSignIn(
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
      scopesSupported: scopes.isNotEmpty ? scopes : asScopes,
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

  /// Step 3: ask the authorization server to describe itself.
  Future<Map<String, dynamic>?> _authServerMetadata(Uri base) async {
    for (final candidate in metadataCandidates(base)) {
      final json = await _json(candidate);
      if (json != null) return json;
    }
    return null;
  }

  /// Where a resource's own metadata could be, in the order worth asking.
  ///
  /// RFC 9728 §3.1 mirrors RFC 8414: the well-known segment goes *between* host
  /// and path, so `https://huggingface.co/mcp` publishes at
  /// `https://huggingface.co/.well-known/oauth-protected-resource/mcp`. Only the
  /// bare origin was tried before, which happened to work for Hugging Face —
  /// they serve both — and would silently miss a resource that serves only the
  /// spelling the RFC names.
  ///
  /// The origin form stays as a fallback for the same reason its counterpart
  /// does: it costs one request on a path already making several, and it is
  /// what several servers actually publish.
  ///
  /// A resource with no path makes the two identical, and only one is yielded.
  /// Built field by field rather than with `replace`, because the resource URL
  /// may carry a query and the metadata URL must not: `replace(query: '')`
  /// leaves a bare `?` on the end, which is a different URL to the server.
  @visibleForTesting
  static Iterable<Uri> resourceMetadataCandidates(Uri resource) sync* {
    const wellKnown = '.well-known/oauth-protected-resource';
    final path = resource.path.replaceAll(RegExp(r'/+$'), '');
    Uri at(String p) => Uri(
      scheme: resource.scheme,
      userInfo: resource.userInfo,
      host: resource.host,
      port: resource.hasPort ? resource.port : null,
      path: p,
    );
    yield at('/$wellKnown$path');
    if (path.isNotEmpty) yield at('/$wellKnown');
  }

  /// Every URL that metadata could be at, in the order worth asking.
  ///
  /// Two axes. **Which document**: RFC 8414's `oauth-authorization-server`
  /// first, then the OpenID one — Linear serves both, Notion and Supabase only
  /// the first.
  ///
  /// **Where the well-known segment goes**, which matters only when the issuer
  /// carries a path. RFC 8414 §3.1 *inserts* it between host and path. This
  /// appended it instead while the comment claimed it was inserting, and the
  /// difference is a whole connector:
  ///
  /// ```
  /// issuer https://access.stripe.com/mcp
  ///   https://access.stripe.com/.well-known/oauth-authorization-server/mcp  200
  ///   https://access.stripe.com/mcp/.well-known/oauth-authorization-server  404
  /// ```
  ///
  /// Measured 2026-07-31 across 26 remote servers: Stripe, monday.com and
  /// GitHub publish only the first form. All three reached the user as "the
  /// sign-in service did not describe itself — you will need to paste a token",
  /// about servers that self-register perfectly. Stripe is the sharpest case:
  /// S256 only, no `plain`, no client secret issued — the cleanest path A of
  /// the whole set, and it was being sent to the Headers box.
  ///
  /// The appended form stays as a fallback. It has never been observed to be
  /// the only one that answers, but it costs one request on a path already
  /// making several, and dropping it would be a second guess where the first
  /// one was already wrong.
  ///
  /// An issuer with no path makes the two forms identical, so only one is
  /// yielded — the common case must not pay for a duplicate request.
  @visibleForTesting
  static Iterable<Uri> metadataCandidates(Uri base) sync* {
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    for (final wellKnown in const [
      '.well-known/oauth-authorization-server',
      '.well-known/openid-configuration',
    ]) {
      yield base.replace(path: '/$wellKnown$path');
      if (path.isNotEmpty) yield base.replace(path: '$path/$wellKnown');
    }
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
  ///
  /// **The quotes are optional.** RFC 7235 lets an auth-param value be a bare
  /// token or a quoted-string, and Stripe sends it bare:
  ///
  /// ```
  /// Bearer resource_metadata=https://mcp.stripe.com/.well-known/oauth-protected-resource
  /// ```
  ///
  /// Requiring quotes read that as "no hint given" and fell through to the
  /// well-known path on the resource's own origin. For Stripe the two happen to
  /// be the same URL, so nothing broke and nothing said anything — which is
  /// exactly why it is worth fixing: the next server to send it bare from a
  /// different location would be probed at the wrong address, silently.
  static _Challenge parse(String header) {
    final trimmed = header.trim();
    if (trimmed.isEmpty) {
      return const _Challenge(resourceMetadata: null, scheme: '');
    }
    final space = trimmed.indexOf(' ');
    final scheme = space < 0 ? trimmed : trimmed.substring(0, space);
    return _Challenge(
      resourceMetadata: resourceMetadataFrom(trimmed),
      scheme: scheme,
    );
  }
}

/// The `resource_metadata` URL out of a `WWW-Authenticate` header, or null when
/// the header doesn't carry one.
///
/// Its own function, and visible for testing, because it is the one piece of
/// step 1 a test can pin without a network — and the header shapes measured in
/// the wild are the whole reason it isn't a one-liner.
///
/// Quoted alternative first, so a quoted value containing a comma is taken
/// whole; the bare alternative stops at whitespace or the next parameter.
@visibleForTesting
Uri? resourceMetadataFrom(String header) {
  final match = RegExp(
    r'resource_metadata\s*=\s*(?:"([^"]+)"|([^\s,]+))',
    caseSensitive: false,
  ).firstMatch(header);
  final value = match?.group(1) ?? match?.group(2);
  return value == null ? null : Uri.tryParse(value);
}

/// Overridable so tests and the dialog share one probe, and no suite reaches the
/// network by accident.
final mcpAuthProbeProvider = Provider<McpAuthProbe>(
  (ref) => const McpAuthProbe(),
);
