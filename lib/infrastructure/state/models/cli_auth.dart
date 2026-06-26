/// Parsed `[auth]` table from `~/.grid/cli.toml` — the file `grid auth login`
/// actually writes in grid 0.1.0. The authenticated session lives here as
/// `api_key` + `user_id`, NOT in `credentials.toml` (which the current CLI no
/// longer produces). This is the source of truth for "is the user signed in".
class CliAuth {
  const CliAuth({
    this.apiKey,
    this.userId,
    this.nodeId,
    this.signalingServerUrl,
  });

  final String? apiKey;
  final String? userId;
  final String? nodeId;
  final String? signalingServerUrl;

  static const empty = CliAuth();

  factory CliAuth.fromToml(Map<String, dynamic> t) {
    final auth = t['auth'];
    if (auth is! Map) return empty;
    final a = auth.cast<String, dynamic>();
    return CliAuth(
      apiKey: a['api_key'] as String?,
      userId: a['user_id'] as String?,
      nodeId: a['node_id'] as String?,
      signalingServerUrl: a['signaling_server_url'] as String?,
    );
  }

  bool get isAuthenticated => apiKey != null && apiKey!.isNotEmpty;

  /// The CLI stores the account identifier (an email) in `user_id`.
  String? get userEmail =>
      (userId != null && userId!.isNotEmpty) ? userId : null;
}
