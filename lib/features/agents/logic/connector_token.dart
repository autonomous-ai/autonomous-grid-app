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
      const prefix = 'Bearer ';
      return auth.startsWith(prefix) ? auth.substring(prefix.length) : auth;
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
        if (key is String && value is String) headers[key] = value;
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

/// One connector's OAuth token, as the app holds it.
///
/// Shaped after RFC 6749 §5.1 (the same shape Hermes's MCP token files use),
/// plus [expiresAt] — an absolute wall-clock instant rather than the spec's
/// relative `expires_in`. A relative lifetime is meaningless once written to
/// disk: after a restart there is nothing to measure it from. Hermes learned
/// this the same way and stores its own `expires_at` for the same reason.
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

  /// True when this connector can actually be used by an agent.
  bool get isUsable => mcpEntry != null;

  /// True when the token is gone or close enough to gone to be worth replacing
  /// before use. [skew] is the head start: refreshing exactly at expiry loses a
  /// race against a request already in flight.
  bool isExpired({DateTime? now, Duration skew = const Duration(minutes: 5)}) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return (now ?? DateTime.now()).isAfter(expiry.subtract(skew));
  }

  /// The gateway can mint a replacement for this token.
  ///
  /// Named separately from [needsRefresh] because the refresh scheduler needs
  /// the question without the clock: "is this worth setting an alarm for" is
  /// asked long before "is it due". Answering it with the entry alone would
  /// skip every connector that has no MCP server yet — those credentials expire
  /// exactly like the rest.
  bool get canBeRefreshed => mcpEntry?.canRefresh ?? refreshToken != null;

  /// Worth calling `/refresh` for now: it expires soon and the provider issues
  /// refresh tokens. Without the second half the call only spends a request.
  bool needsRefresh({DateTime? now}) => isExpired(now: now) && canBeRefreshed;

  ConnectorToken copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? scope,
    String? tokenType,
    String? accountName,
    McpEntry? mcpEntry,
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
    );
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'token_type': tokenType,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (expiresAt != null)
      'expires_at': expiresAt!.millisecondsSinceEpoch ~/ 1000,
    if (scope.isNotEmpty) 'scope': scope,
    if (accountName.isNotEmpty) 'account_name': accountName,
    if (mcpEntry != null) 'mcp_entry': mcpEntry!.toJson(),
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
    );
  }
}
