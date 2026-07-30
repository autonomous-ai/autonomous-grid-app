import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// One OAuth client this machine registered for itself (RFC 7591).
///
/// Registration is a *separate lifetime* from a token, which is why this is its
/// own file and not a field on `ConnectorToken`:
///
/// - A `client_id` is durable; an `access_token` lives about an hour.
/// - Disconnecting forgets the token but **keeps** this. Re-registering on every
///   reconnect would leave a trail of dead app entries in the user's account
///   settings at the provider — one per sign-in.
/// - Refreshing needs the `client_id` (and, for some servers, the secret), so
///   losing this file turns every DCR token into one that cannot be renewed.
class DcrClient {
  const DcrClient({
    required this.issuer,
    required this.clientId,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.clientSecret,
    this.authMethod = 'none',
    this.redirectUri = '',
    this.registeredAt,
  });

  /// The authorization server's issuer — the key this is stored under.
  final String issuer;

  final String clientId;

  /// Present only when the authorization server issued one.
  ///
  /// Measured 2026-07-30: Notion and Linear issue **no** secret and accept
  /// `token_endpoint_auth_method: none`; Supabase issues a 44-character secret
  /// and advertises only `client_secret_basic` / `client_secret_post`. So a
  /// dynamically registered client is not always a public client, and the token
  /// call has to be built from [authMethod] rather than assumed.
  final String? clientSecret;

  /// How the token call authenticates: `none`, `client_secret_post`, or
  /// `client_secret_basic`.
  final String authMethod;

  final String authorizationEndpoint;
  final String tokenEndpoint;

  /// The exact `redirect_uri` this client was registered with.
  ///
  /// Stored because it is what makes the registration *reusable*: the authorize
  /// call must present a URI the client is registered for, and the token
  /// exchange must then repeat it byte for byte (RFC 6749 §4.1.3).
  ///
  /// RFC 8252 §7.3 asks authorization servers to accept any loopback port for a
  /// native client, but measured 2026-07-30 not all do — Achriom answers
  /// `invalid_redirect_uri` for a port it did not see at registration. Hence the
  /// stable port in `OAuthLoopbackListener.preferredPorts`, and hence this being
  /// compared rather than assumed compatible.
  final String redirectUri;

  final DateTime? registeredAt;

  bool get isPublic => authMethod == 'none' || clientSecret == null;

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    if (clientSecret != null) 'client_secret': clientSecret,
    'token_endpoint_auth_method': authMethod,
    'authorization_endpoint': authorizationEndpoint,
    'token_endpoint': tokenEndpoint,
    if (redirectUri.isNotEmpty) 'redirect_uri': redirectUri,
    if (registeredAt != null)
      'registered_at': registeredAt!.millisecondsSinceEpoch ~/ 1000,
  };

  /// Read one entry, or null when it carries nothing usable — a single bad row
  /// drops itself rather than taking the store down.
  static DcrClient? fromJson(String issuer, Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['client_id'];
    final authorize = raw['authorization_endpoint'];
    final token = raw['token_endpoint'];
    if (id is! String || id.isEmpty) return null;
    if (authorize is! String || authorize.isEmpty) return null;
    if (token is! String || token.isEmpty) return null;
    final issued = raw['registered_at'];
    return DcrClient(
      issuer: issuer,
      clientId: id,
      clientSecret: raw['client_secret'] is String
          ? raw['client_secret'] as String
          : null,
      authMethod: raw['token_endpoint_auth_method'] is String
          ? raw['token_endpoint_auth_method'] as String
          : 'none',
      authorizationEndpoint: authorize,
      tokenEndpoint: token,
      redirectUri: raw['redirect_uri'] is String
          ? raw['redirect_uri'] as String
          : '',
      registeredAt: issued is int && issued > 0
          ? DateTime.fromMillisecondsSinceEpoch(issued * 1000)
          : null,
    );
  }
}

/// The registrations this machine holds: `~/.grid/connectors/clients.json`,
/// mode `600`.
///
/// App-owned and agent-neutral, the third file in the same directory as
/// `tokens.json` and `manual.json`, for the same reason as both: the app is the
/// OAuth client here, not any one agent. If Hermes registered its own client the
/// user would consent again for Codex, and a third time for Claude Code — which
/// is exactly what rule 4 forbids for skills and D10 forbids for tokens.
///
/// **Why `600` and not the OS credential store.** This can hold a
/// `client_secret`, so it is as sensitive as `tokens.json` — and it takes the
/// same D11 exception, for a narrower reason: the token refresh that needs this
/// secret runs on a schedule while the app is open, and a Keychain item that
/// wants an unlocked session or a prompt would stall it. Keeping the pair
/// together in one directory with one mode also means there is one thing to
/// protect rather than two half-measures.
///
/// Keyed by **issuer**, not by MCP URL or connector code. Supabase is why:
/// `mcp.supabase.com` is the resource while `api.supabase.com` is the
/// authorization server, and two MCP servers behind one authorization server
/// should share a single registration instead of making two.
class DcrClientStore {
  DcrClientStore({Directory? home}) : _home = home;

  /// Overridable so tests write into a temp dir and never touch the real
  /// `~/.grid`.
  final Directory? _home;

  Directory get directory => _home == null
      ? GridPaths.connectorsDir
      : Directory('${_home.path}/connectors');

  File get file => File('${directory.path}/clients.json');

  /// Every registration, keyed by issuer.
  ///
  /// A missing file is an empty store, and so is one that won't parse: refusing
  /// to load would block the screen that could fix it, and the worst case is one
  /// extra registration rather than lost data.
  Future<Map<String, DcrClient>> read() async {
    if (!await file.exists()) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      return {};
    }
    if (decoded is! Map<String, dynamic>) return {};

    final clients = <String, DcrClient>{};
    for (final entry in decoded.entries) {
      final client = DcrClient.fromJson(entry.key, entry.value);
      if (client != null) clients[entry.key] = client;
    }
    return clients;
  }

  /// Replace the whole store. Callers go through [save].
  ///
  /// Verifies the file exists afterwards rather than trusting the write to have
  /// landed. `writeAsString` succeeding says the bytes left this process, not
  /// that they reached the path anyone will read later — and a registration that
  /// silently fails to persist re-registers on every connect, leaving a trail of
  /// dead app entries in the user's account at the provider.
  Future<void> write(Map<String, DcrClient> clients) async {
    await directory.create(recursive: true);
    final payload = {
      for (final entry in clients.entries) entry.key: entry.value.toJson(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    if (!await file.exists()) {
      throw FileSystemException(
        'Registration store vanished after writing',
        file.path,
      );
    }
    await _restrictPermissions();
  }

  /// The registration for [issuer], or null when this machine has none.
  Future<DcrClient?> find(String issuer) async => (await read())[issuer];

  /// Add or replace one registration, leaving the others untouched.
  Future<void> save(DcrClient client) async {
    final clients = await read();
    clients[client.issuer] = client;
    await write(clients);
  }

  Future<void> remove(String issuer) async {
    final clients = await read();
    if (clients.remove(issuer) == null) return;
    await write(clients);
  }

  /// Owner-only, best-effort — same reasoning as the token store: a weaker mode
  /// beats an abandoned write, since losing this means the connector silently
  /// stops being renewable.
  Future<void> _restrictPermissions() async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } on Object {
      // Nothing to do and nothing to say.
    }
  }
}

/// Overridable so tests point at a temp home and never read or write the real
/// `~/.grid/connectors`.
final dcrClientStoreProvider = Provider<DcrClientStore>(
  (ref) => DcrClientStore(),
);
