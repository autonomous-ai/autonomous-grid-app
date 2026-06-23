import 'network_credential.dart';

/// Parsed `~/.grid/credentials.toml` (cli.py:349). Holds the session and the
/// list of joined networks. See CLI_Integration_Contract §1.1.
class CredentialsFile {
  const CredentialsFile({
    required this.networks,
    this.apiUrl,
    this.sessionToken,
    this.activeNetwork,
    this.user = const {},
  });

  final String? apiUrl;
  final String? sessionToken;
  final String? activeNetwork;
  final Map<String, dynamic> user;
  final List<NetworkCredential> networks;

  static const empty = CredentialsFile(networks: []);

  factory CredentialsFile.fromToml(Map<String, dynamic> t) {
    final rawNetworks = t['networks'];
    final networks = rawNetworks is List
        ? rawNetworks
            .whereType<Map>()
            .map((n) => NetworkCredential.fromToml(n.cast<String, dynamic>()))
            .toList()
        : <NetworkCredential>[];
    final user = t['user'];
    return CredentialsFile(
      apiUrl: t['api_url'] as String?,
      sessionToken: t['session_token'] as String?,
      activeNetwork: t['active_network'] as String?,
      user: user is Map ? user.cast<String, dynamic>() : const {},
      networks: networks,
    );
  }

  bool get isLoggedIn =>
      sessionToken != null && sessionToken!.isNotEmpty;

  String? get userEmail => user['email'] as String?;

  /// The selected network: `active_network` if present, else the first.
  NetworkCredential? get active {
    if (networks.isEmpty) return null;
    for (final n in networks) {
      if (n.networkId == activeNetwork) return n;
    }
    return networks.first;
  }

  NetworkCredential? byName(String nameOrId) {
    for (final n in networks) {
      if (n.networkId == nameOrId || n.name == nameOrId) return n;
    }
    return null;
  }
}
