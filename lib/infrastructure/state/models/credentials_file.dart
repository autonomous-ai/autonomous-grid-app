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

  /// Legacy `active_network` from the single-mode CLI. The dual-mode CLI moved
  /// the active selection to `state.json`; kept here only as a fallback for a
  /// pre-migration `credentials.toml`. New code reads the active grid via
  /// `activeRemoteGridProvider`.
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

  bool get isLoggedIn => sessionToken != null && sessionToken!.isNotEmpty;

  String? get userEmail => user['email'] as String?;

  String? get userName => user['name'] as String?;

  /// The grid that matches the signed-in user's email domain — a `-domain` grid
  /// named for that domain (`dev@autonomous.ai` → the "autonomous.ai" grid). It's
  /// the user's home/org grid, so it's the natural default after login rather
  /// than an arbitrary first grid they may only consume on. Null when the email
  /// has no domain or no grid matches.
  NetworkCredential? get domainGrid {
    final email = userEmail;
    final at = email == null ? -1 : email.indexOf('@');
    if (at < 0) return null;
    final domain = email!.substring(at + 1).toLowerCase();
    if (domain.isEmpty) return null;
    return _firstWhere(
      (n) => n.networkType.contains('domain') && n.name.toLowerCase() == domain,
    );
  }

  /// Fallback selection when nothing on disk points at a grid: the legacy
  /// `active_network` if present, then the login-domain (org) grid, then a
  /// private grid the user owns, then any owned grid, then the first private
  /// grid, else the first grid. The primary active grid comes from `state.json`
  /// (see `activeRemoteGridProvider` / [SelectedNetwork]).
  ///
  /// Signing in with a company email means the company grid — it outranks a
  /// grid the user merely happens to own, because owner-first sent a user with
  /// a throwaway public test grid onto *that* grid, and the app then shared
  /// their computer there. Public never wins a tie for the same reason: landing
  /// on a public grid by default offers this machine's model to strangers.
  NetworkCredential? get active {
    if (networks.isEmpty) return null;
    return _firstWhere((n) => n.networkId == activeNetwork) ??
        domainGrid ??
        _firstWhere((n) => n.isOwner && !n.isPublic) ??
        _firstWhere((n) => n.isOwner) ??
        _firstWhere((n) => !n.isPublic) ??
        networks.first;
  }

  NetworkCredential? byName(String nameOrId) =>
      _firstWhere((n) => n.networkId == nameOrId || n.name == nameOrId);

  NetworkCredential? _firstWhere(bool Function(NetworkCredential) test) {
    for (final n in networks) {
      if (test(n)) return n;
    }
    return null;
  }
}
