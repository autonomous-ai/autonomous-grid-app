/// The viewer's governance role on a network, taken from the `roles` claim.
/// Distinct from [NetworkCredential.isProvider], which is a *capability*
/// (the `provider:poll` scope), not a role.
enum NetworkRole { admin, provider, consumer, member }

/// One Grid network's credentials bundle, as stored under `[[networks]]` in
/// `~/.grid/credentials.toml`. Mirrors the CLI `NetworkCredentials` dataclass
/// (config.py:25). See CLI_Integration_Contract §1.1.
class NetworkCredential {
  const NetworkCredential({
    required this.networkId,
    required this.name,
    required this.networkType,
    required this.lanSignalingUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.email,
    required this.nodeId,
    required this.deviceId,
    required this.roles,
    required this.scopes,
    required this.memberEpoch,
    required this.networkEpoch,
    required this.expiresAt,
    this.refreshExpiresAt,
  });

  final String networkId;
  final String name;
  final String networkType;
  final String lanSignalingUrl;
  final String accessToken;
  final String refreshToken;
  final String email;
  final String nodeId;
  final String deviceId;
  final List<String> roles;
  final List<String> scopes;
  final int memberEpoch;
  final int networkEpoch;
  final int expiresAt;
  final int? refreshExpiresAt;

  factory NetworkCredential.fromToml(Map<String, dynamic> t) {
    return NetworkCredential(
      networkId: t['network_id'] as String,
      name: (t['name'] ?? t['network_id']) as String,
      networkType: (t['network_type'] ?? 'permissioned') as String,
      lanSignalingUrl: _trimSlash(t['lan_signaling_url'] as String),
      accessToken: t['access_token'] as String,
      refreshToken: (t['refresh_token'] ?? '') as String,
      email: (t['email'] ?? '') as String,
      nodeId: (t['node_id'] ?? '') as String,
      deviceId: (t['device_id'] ?? '') as String,
      roles: _stringList(t['roles']),
      scopes: _stringList(t['scopes']),
      memberEpoch: (t['member_epoch'] ?? 1) as int,
      networkEpoch: (t['network_epoch'] ?? 1) as int,
      expiresAt: (t['expires_at'] ?? 0) as int,
      refreshExpiresAt: t['refresh_expires_at'] as int?,
    );
  }

  /// Data-plane base URL — exactly what `grid info --env` prints, derived
  /// locally so we never have to shell out for it.
  String get relayBaseUrl => '$lanSignalingUrl/relay/v1';

  String get relayApiKey => accessToken;

  /// Capability gate for the provider UI — the CLI requires this scope to run
  /// a provider (cli.py:679). Independent of [role] (an admin may or may not
  /// also hold provider:poll).
  bool get isProvider => scopes.contains('provider:poll');

  /// The viewer's governance role, read from the `roles` claim — the same value
  /// the web console shows (Admin / Consumer / …).
  NetworkRole get role {
    if (roles.contains('admin')) return NetworkRole.admin;
    if (roles.contains('provider')) return NetworkRole.provider;
    if (roles.contains('consumer')) return NetworkRole.consumer;
    return NetworkRole.member;
  }

  /// Plain-language label for [role] (badge text) — describes what you do on the
  /// grid: a "provider" shares a model, a "consumer" uses one. Deliberately
  /// avoids the words Public/Private, which are reserved for grid *visibility*
  /// ([visibilityLabel]) — reusing them for roles read as a settings collision.
  String get roleLabel => switch (role) {
    NetworkRole.admin => 'Owner',
    NetworkRole.provider => 'Sharing',
    NetworkRole.consumer => 'Using',
    NetworkRole.member => 'Member',
  };

  /// Whether the grid is publicly visible. Heads-up: the wire values read
  /// backwards, so this is deliberately checked against `providers`, not
  /// `public`. A `permissionless` grid is the *public* one — anyone it's
  /// shared with can also share their models onto it — whereas
  /// `permissioned-public` is actually *private*: visible only to people it has
  /// been shared with. Do NOT "fix" this to `contains('public')`; that inverts
  /// the product meaning.
  bool get isPublic => networkType.contains('providers');

  /// The grid's visibility: `Public` vs `Private`. Surfaced on the grid badge
  /// (a public grid the viewer merely joined) and in admin settings.
  String get visibilityLabel => isPublic ? 'Public' : 'Private';

  /// May the viewer reach the Provider/Models tabs on this network? Admins
  /// manage the network so they always can; otherwise the provider:poll
  /// capability is required. (Pure consumers/members are excluded.)
  bool get canManageProvider => role == NetworkRole.admin || isProvider;

  /// Whether the viewer owns/administers this grid — the only role the control
  /// plane lets manage membership (invite / remove members, delete the grid)
  /// today. Providers can serve a model but can't manage members yet (BE support
  /// pending), so member-admin UI must gate on this, not [canManageProvider].
  bool get isOwner => role == NetworkRole.admin;

  /// Whether the stored access token has run out — "no", rather than "yes",
  /// when the record doesn't say.
  ///
  /// [expiresAt] defaults to 0 for a `[[networks]]` block written before the
  /// field existed, and a bare `now >= 0` reads that as expired in 1970. This
  /// gates whether the app will point an assistant at the grid at all, so a
  /// missing field would take working chats away from anyone whose credentials
  /// predate it — the same shape as the `archivedAt` epoch trap.
  bool isExpired(DateTime now) =>
      expiresAt > 0 && now.millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  static List<String> _stringList(Object? value) =>
      value is List ? value.map((e) => e.toString()).toList() : const [];

  static String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
