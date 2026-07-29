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
    this.mcpUrl = '',
    this.tokenType = 'Bearer',
  });

  /// The catalog `code` this token belongs to (`gmail`, `slack`). Also the key
  /// in the store and, for Hermes, the MCP server name it projects to.
  final String connector;

  final String accessToken;

  /// Present when the provider issued one. Whether an agent may *use* it is a
  /// separate question — a gateway-issued token refreshes through the gateway,
  /// not from this machine (see the spec, §6c).
  final String? refreshToken;

  /// When [accessToken] stops working. Null when the provider didn't say, which
  /// means "no reason to refresh early" — not "already expired".
  final DateTime? expiresAt;

  final String scope;

  /// The provider's MCP endpoint, carried so a projection can write the server
  /// entry and the token together instead of joining two sources.
  final String mcpUrl;

  final String tokenType;

  /// True when the token is gone or close enough to gone to be worth replacing
  /// before use. [skew] is the head start: refreshing exactly at expiry loses a
  /// race against a request already in flight.
  bool isExpired({DateTime? now, Duration skew = const Duration(minutes: 5)}) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return (now ?? DateTime.now()).isAfter(expiry.subtract(skew));
  }

  ConnectorToken copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? scope,
    String? mcpUrl,
    String? tokenType,
  }) {
    return ConnectorToken(
      connector: connector,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      scope: scope ?? this.scope,
      mcpUrl: mcpUrl ?? this.mcpUrl,
      tokenType: tokenType ?? this.tokenType,
    );
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'token_type': tokenType,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (expiresAt != null)
      'expires_at': expiresAt!.millisecondsSinceEpoch ~/ 1000,
    if (scope.isNotEmpty) 'scope': scope,
    if (mcpUrl.isNotEmpty) 'mcp_url': mcpUrl,
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
      mcpUrl: raw['mcp_url'] is String ? raw['mcp_url'] as String : '',
      tokenType: raw['token_type'] is String
          ? raw['token_type'] as String
          : 'Bearer',
    );
  }
}
