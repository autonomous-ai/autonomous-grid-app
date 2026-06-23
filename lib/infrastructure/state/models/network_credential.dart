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

  /// Data-plane base URL — exactly what `consumer env` prints (cli.py:879),
  /// derived locally so we never have to shell out for it.
  String get relayBaseUrl => '$lanSignalingUrl/relay/v1';

  String get relayApiKey => accessToken;

  /// Gate for provider UI — the CLI requires this scope (cli.py:679).
  bool get isProvider => scopes.contains('provider:poll');

  /// The viewer's role on this network. Drives the role badge and which nav
  /// sections (Provider/Models) are available.
  String get roleLabel => isProvider ? 'Provider' : 'Consumer';

  bool isExpired(DateTime now) =>
      now.millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  static List<String> _stringList(Object? value) =>
      value is List ? value.map((e) => e.toString()).toList() : const [];

  static String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
