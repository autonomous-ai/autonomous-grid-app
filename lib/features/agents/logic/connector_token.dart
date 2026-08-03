import 'rest_entry.dart';

/// The MCP server entry the gateway renders for a connector.
///
/// The gateway builds this **per provider's own header convention** — most use
/// `Authorization: Bearer`, Figma uses `X-Figma-Token` — so the app never has
/// to know how a given provider expects to be addressed. Adding a provider with
/// an unusual header is a config row on the server and no app change at all.
///
/// Store it verbatim. Re-deriving it from the token would throw away the one
/// thing the server knew and we don't.
class McpEntry {
  const McpEntry({
    required this.url,
    this.headers = const {},
    this.expiresAt,
    this.canRefresh = false,
  });

  final String url;

  /// Already carries the live credential. Never log this map.
  final Map<String, String> headers;

  /// From `_grid.expires_at` — the mark a refresh sweep watches.
  final DateTime? expiresAt;

  /// From `_grid.refresh`. False means the provider issues no refresh token, so
  /// calling `/refresh` only spends a request.
  final bool canRefresh;

  /// The bearer credential, for agents that want the token rather than the
  /// whole entry — Hermes writes it into its own token store instead of taking
  /// the headers (see `HermesTokenProjection`).
  ///
  /// Falls back to any single header value when the provider doesn't use
  /// `Authorization`, because for those the header value *is* the credential.
  String? get bearerToken {
    final auth = headers['Authorization'] ?? headers['authorization'];
    if (auth != null) {
      // Case-insensitively, because the scheme is (RFC 7235 §2.1) and because a
      // stored header may predate the normalisation in [fromJson]. Matching
      // `Bearer ` literally returned the *whole* header as the token for an
      // entry written `bearer …`, and Hermes then filed `bearer sbp_…` as the
      // credential itself.
      final space = auth.indexOf(' ');
      if (space > 0 && auth.substring(0, space).toLowerCase() == 'bearer') {
        return auth.substring(space + 1);
      }
      return auth;
    }
    return headers.length == 1 ? headers.values.first : null;
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    if (headers.isNotEmpty) 'headers': headers,
    '_grid': {
      if (expiresAt != null)
        'expires_at': expiresAt!.millisecondsSinceEpoch ~/ 1000,
      'refresh': canRefresh,
    },
  };

  /// Reads the gateway's `mcp_entry`. Null when there's no usable URL — an
  /// entry without one can't be written into any agent's config.
  static McpEntry? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;

    final headers = <String, String>{};
    final rawHeaders = raw['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String) {
          headers[key] = _normalizeAuth(key, value);
        }
      }
    }

    final grid = raw['_grid'];
    final expiry = grid is Map ? grid['expires_at'] : null;
    return McpEntry(
      url: url,
      headers: headers,
      expiresAt: expiry is int && expiry > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiry * 1000)
          : null,
      canRefresh: grid is Map && grid['refresh'] == true,
    );
  }
}

/// Repair a stored `Authorization` header whose scheme is spelled `bearer`.
///
/// **On read, so a token already on disk is fixed without being re-fetched.**
/// The header is minted correctly now (`bearerScheme` in `dcr_oauth_client`),
/// but an entry written before that carries the provider's own lowercase answer
/// — and the provider then refuses it:
///
/// ```
/// mcp.canva.com   "bearer <token>"  401
/// mcp.canva.com   "Bearer <token>"  200
/// ```
///
/// Measured 2026-08-03 on canva, cloudflare and postman, all three with hours
/// left on the credential. Without this, those keep failing until each one's
/// next renewal happens to rewrite the entry — up to an hour of an agent that
/// reports "unauthorized" about a perfectly good token.
///
/// Only the scheme is touched, and only when it is bearer: the token itself is
/// never rewritten, and a server using DPoP or something of its own keeps its
/// spelling.
String _normalizeAuth(String key, String value) {
  if (key.toLowerCase() != 'authorization') return value;
  final space = value.indexOf(' ');
  if (space <= 0) return value;
  final scheme = value.substring(0, space);
  if (scheme.toLowerCase() != 'bearer' || scheme == 'Bearer') return value;
  return 'Bearer${value.substring(space)}';
}

/// Who obtained a token, and therefore who can renew it.
///
/// Not cosmetic: the two paths have different renewal and revocation endpoints,
/// and calling the wrong one fails in a confusing way. Asking the gateway to
/// `/refresh` a [dcr] connector asks it about a credential it has never seen;
/// refreshing a [gateway] connector locally is impossible, because the
/// `client_secret` it would need lives on the server by design.
enum ConnectorTokenSource {
  /// The Grid gateway brokered it (path B) — `/poll` delivered it, `/refresh`
  /// renews it, `/disconnect` forgets it.
  gateway,

  /// The app registered itself with the provider and ran OAuth directly
  /// (path A, RFC 7591 + 7636). Renewed locally by `DcrOAuthClient`; the Grid
  /// backend knows nothing about it.
  dcr,
}

/// One connector's OAuth token, as the app holds it.
///
/// Shaped after RFC 6749 §5.1 (the same shape Hermes's MCP token files use),
/// plus [expiresAt] — an absolute wall-clock instant rather than the spec's
/// relative `expires_in`. A relative lifetime is meaningless once written to
/// disk: after a restart there is nothing to measure it from. Hermes learned
/// this the same way and stores its own `expires_at` for the same reason.
///
/// Deliberately identical for both OAuth paths. A gateway-brokered token and a
/// self-registered one differ only in [source] and [issuer]; everything
/// downstream — the master store, each agent's projection, the refresh sweep —
/// reads the same fields and cannot tell them apart.
class ConnectorToken {
  const ConnectorToken({
    required this.connector,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scope = '',
    this.tokenType = 'Bearer',
    this.accountName = '',
    this.mcpEntry,
    this.restEntry,
    this.declaredTransport,
    this.canRefresh,
    this.source = ConnectorTokenSource.gateway,
    this.issuer = '',
  });

  /// The catalog `code` this token belongs to (`linear`, `notion`). Also the
  /// key in the store and, for Hermes, the MCP server name it projects to.
  final String connector;

  final String accessToken;

  /// Present when the provider issued one. Refreshing is the *gateway's* job,
  /// not this machine's — the app calls `/refresh` and gets a new token back.
  final String? refreshToken;

  /// When [accessToken] stops working. Null when the provider didn't say, which
  /// means "no reason to refresh early" — not "already expired".
  final DateTime? expiresAt;

  final String scope;

  final String tokenType;

  /// The account this token belongs to at the provider, when they say. Shown on
  /// the row so a user with two accounts can tell which one is linked.
  final String accountName;

  /// The server-rendered MCP entry, or null when this connector has no MCP
  /// server at all.
  ///
  /// Null is a real and reachable state: five connectors are OAuth-capable with
  /// nothing behind them. The account genuinely links, and the agent still
  /// can't call anything — which is why the screen gates on `mcpReady` long
  /// before it gets here.
  final McpEntry? mcpEntry;

  /// The provider's REST surface, described by the gateway, for a connector no
  /// MCP server can serve.
  ///
  /// Gmail is why this exists. Google's MCP server accepts only
  /// `gmail.readonly` / `gmail.modify` / `mail.google.com`; an organisation can
  /// grant `gmail.send` and nothing more, and then no MCP server on earth will
  /// take the token — while the REST API happily sends mail with it. The gap is
  /// permanent, not a backlog item, so it needs a second way in rather than a
  /// wait.
  ///
  /// The agent never sees any of this. `ConnectorBridge` serves these as
  /// ordinary MCP tools over loopback, which is what keeps the whole idea
  /// invisible to the projection layer and free across agents.
  final RestEntry? restEntry;

  /// What the gateway said to use, or null when it said nothing.
  ///
  /// Kept separate from the *effective* answer (`effectiveTransport`) because
  /// the gateway can declare something this build cannot honour — `mcp` with no
  /// entry attached — and a stored declaration must not be rewritten into a
  /// decision the app made on its behalf.
  final ConnectorTransport? declaredTransport;

  /// Whether this can be renewed, from the top-level `refresh` on a `/poll` or
  /// `/refresh` payload — or, on path A, from whether the provider's token
  /// response actually carried a `refresh_token`.
  ///
  /// Authoritative, and the only source that survives [mcpEntry] being null —
  /// which is precisely the case that matters, since a connector with no MCP
  /// server still holds a one-hour Google token. The copy inside
  /// `mcpEntry._grid` says the same thing but disappears with the entry.
  ///
  /// Both paths fill it, so the stored shape reads the same either way. A
  /// self-registered token used to leave it null and lean on the entry's copy —
  /// which worked, and meant a file full of `"refresh": true` gateway entries
  /// next to DCR entries with no such line, inviting exactly the question of
  /// whether the second kind renews at all.
  ///
  /// Null means "the gateway didn't say": a token written to disk before this
  /// field existed, or a payload from an older control plane. Kept nullable so
  /// those keep refreshing off the old inference instead of silently going
  /// stale after an app update — see [canBeRefreshed].
  final bool? canRefresh;

  /// Which path obtained this, and so which one can renew it.
  final ConnectorTokenSource source;

  /// The authorization server's issuer — set only for [ConnectorTokenSource.dcr].
  ///
  /// The key into `clients.json`: renewing a self-registered token needs the
  /// `client_id` that was registered, and this is how it's found again. Empty for
  /// gateway tokens, which carry no local registration.
  final String issuer;

  /// True when the gateway described *some* way for an agent to reach this.
  ///
  /// Says nothing about the local fallback in `rest_entry_fallback.dart`, which
  /// lives a layer up: this is "what the server told us", and mixing a local
  /// stand-in into it would make the two indistinguishable in the one place the
  /// difference matters — deciding whether the backend still owes us anything.
  /// Callers wanting the effective answer use `effectiveTransport`.
  bool get isUsable => mcpEntry != null || restEntry != null;

  /// True when the token is gone or close enough to gone to be worth replacing
  /// before use. [skew] is the head start: refreshing exactly at expiry loses a
  /// race against a request already in flight.
  bool isExpired({DateTime? now, Duration skew = const Duration(minutes: 5)}) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return (now ?? DateTime.now()).isAfter(expiry.subtract(skew));
  }

  /// A replacement can be minted for this token — by the gateway for a
  /// [ConnectorTokenSource.gateway] token, or by the app itself for a
  /// [ConnectorTokenSource.dcr] one.
  ///
  /// Named separately from [needsRefresh] because the refresh scheduler needs
  /// the question without the clock: "is this worth setting an alarm for" is
  /// asked long before "is it due". Answering it with the entry alone would
  /// skip every connector that has no MCP server yet — those credentials expire
  /// exactly like the rest.
  ///
  /// Deliberately source-agnostic. Path A sets `mcpEntry.canRefresh` from
  /// whether the provider actually issued a `refresh_token`, so one predicate
  /// serves both paths and the scheduler never has to branch on [source] — only
  /// the controller does, when it picks *which* endpoint to call.
  ///
  /// Three sources, most authoritative first:
  ///
  /// 1. [canRefresh] — what the gateway said, present for every connector.
  /// 2. `mcpEntry.canRefresh` — the same answer, but only when there is an entry.
  /// 3. "did the provider hand back a refresh_token" — the inference used before
  ///    the gateway carried the flag. Only reached for tokens stored by an older
  ///    build; a *non-empty* token, since the payload spells "none" as `""` and
  ///    an empty string is still a String.
  bool get canBeRefreshed =>
      canRefresh ??
      mcpEntry?.canRefresh ??
      (refreshToken != null && refreshToken!.isNotEmpty);

  /// Worth refreshing now: it expires soon and a replacement can be obtained.
  /// Without the second half the call only spends a request.
  bool needsRefresh({DateTime? now}) => isExpired(now: now) && canBeRefreshed;

  ConnectorToken copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? scope,
    String? tokenType,
    String? accountName,
    McpEntry? mcpEntry,
    RestEntry? restEntry,
    ConnectorTransport? declaredTransport,
    bool? canRefresh,
    ConnectorTokenSource? source,
    String? issuer,
  }) {
    return ConnectorToken(
      connector: connector,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      scope: scope ?? this.scope,
      tokenType: tokenType ?? this.tokenType,
      accountName: accountName ?? this.accountName,
      mcpEntry: mcpEntry ?? this.mcpEntry,
      restEntry: restEntry ?? this.restEntry,
      declaredTransport: declaredTransport ?? this.declaredTransport,
      canRefresh: canRefresh ?? this.canRefresh,
      source: source ?? this.source,
      issuer: issuer ?? this.issuer,
    );
  }

  /// Fold a freshly-issued [replacement] onto this token.
  ///
  /// **Why refresh is a merge and not an assignment.** `/refresh` answers a
  /// narrow question — here is a live credential — and its payload carries only
  /// what that question needs. Everything else about the connector (`scope`,
  /// `account_name`, `mcp_entry`, `rest_entry`) is *description*, issued once at
  /// sign-in and unchanged by a renewal.
  ///
  /// Storing the reply wholesale therefore erased those fields on every sweep.
  /// Measured on 2026-07-31: `gmail` lost its `scope` and `account_name` about
  /// an hour after linking, and with `scope` gone there is no way left to tell
  /// which transport the grant can reach — the connector reads as unusable while
  /// its credential is perfectly good.
  ///
  /// The credential fields below are the *only* ones a renewal owns. A field it
  /// omits is not a field it cleared.
  ConnectorToken mergeRefreshed(ConnectorToken replacement) => ConnectorToken(
    connector: connector,
    accessToken: replacement.accessToken,
    refreshToken: replacement.refreshToken ?? refreshToken,
    expiresAt: replacement.expiresAt ?? expiresAt,
    tokenType: replacement.tokenType,
    // Description: kept unless the reply actually restates it.
    scope: replacement.scope.isNotEmpty ? replacement.scope : scope,
    accountName: replacement.accountName.isNotEmpty
        ? replacement.accountName
        : accountName,
    mcpEntry: replacement.mcpEntry ?? mcpEntry,
    restEntry: replacement.restEntry ?? restEntry,
    declaredTransport: replacement.declaredTransport ?? declaredTransport,
    canRefresh: replacement.canRefresh ?? canRefresh,
    // Identity of the credential's issuer never changes under a renewal, and a
    // reply that omits `source` must not silently demote a DCR token to a
    // gateway one — the refresh sweep would then call the wrong endpoint.
    source: source,
    issuer: issuer.isNotEmpty ? issuer : replacement.issuer,
  );

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'token_type': tokenType,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (expiresAt != null)
      'expires_at': expiresAt!.millisecondsSinceEpoch ~/ 1000,
    if (scope.isNotEmpty) 'scope': scope,
    if (accountName.isNotEmpty) 'account_name': accountName,
    if (mcpEntry != null) 'mcp_entry': mcpEntry!.toJson(),
    if (restEntry != null) 'rest_entry': restEntry!.toJson(),
    if (declaredTransport != null) 'transport': declaredTransport!.name,
    // Omitted when the gateway didn't say, so it reads back as null rather than
    // as a decision nobody made — the distinction [canBeRefreshed] relies on.
    if (canRefresh != null) 'refresh': canRefresh,
    // Only written for the non-default path, so every token already on disk
    // stays byte-identical and reads back as `gateway` — see [fromJson].
    if (source != ConnectorTokenSource.gateway) 'source': source.name,
    if (issuer.isNotEmpty) 'issuer': issuer,
  };

  /// Read one entry. Returns null when there's no usable token, so a single
  /// corrupt row drops itself instead of taking the whole store down with it.
  static ConnectorToken? fromJson(String connector, Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final access = raw['access_token'];
    if (access is! String || access.isEmpty) return null;
    final expiry = raw['expires_at'];
    return ConnectorToken(
      connector: connector,
      accessToken: access,
      refreshToken: raw['refresh_token'] is String
          ? raw['refresh_token'] as String
          : null,
      expiresAt: expiry is int
          ? DateTime.fromMillisecondsSinceEpoch(expiry * 1000)
          : null,
      scope: raw['scope'] is String ? raw['scope'] as String : '',
      tokenType: raw['token_type'] is String
          ? raw['token_type'] as String
          : 'Bearer',
      accountName: raw['account_name'] is String
          ? raw['account_name'] as String
          : '',
      mcpEntry: McpEntry.fromJson(raw['mcp_entry']),
      restEntry: RestEntry.fromJson(raw['rest_entry']),
      declaredTransport: parseTransport(raw['transport']),
      // Left null when absent — a token stored before the gateway carried the
      // flag must keep falling back, not read as "cannot refresh".
      canRefresh: raw['refresh'] is bool ? raw['refresh'] as bool : null,
      // Absent means gateway: every token written before path A existed came
      // from there, and reading a missing field as `dcr` would send the refresh
      // sweep looking for a `clients.json` registration that never existed.
      source: raw['source'] == 'dcr'
          ? ConnectorTokenSource.dcr
          : ConnectorTokenSource.gateway,
      issuer: raw['issuer'] is String ? raw['issuer'] as String : '',
    );
  }
}
