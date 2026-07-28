import 'dart:convert';

/// One third-party app the user can connect (Linear, Slack, Notion, …).
///
/// Mirrors a row from `grid connector list --json`, which the CLI passes through
/// from the control plane. The app never talks to a provider itself — it only
/// drives the CLI.
class Connector {
  const Connector({
    required this.code,
    required this.connected,
    required this.mcpReady,
    required this.authType,
    this.accountName = '',
  });

  /// Stable id shared with the backend and the provider's OAuth app ("linear").
  final String code;
  final bool connected;

  /// Whether an MCP server exists for this connector. When false the OAuth flow
  /// still succeeds, but nothing is wired for the agent to call — so the UI must
  /// not offer a Connect button that leads nowhere useful.
  final bool mcpReady;

  /// "app" (OAuth, browser flow) or "pat" (the user pastes a token — the CLI
  /// cannot drive that yet).
  final String authType;

  /// Which account the credential belongs to, when the provider told us.
  final String accountName;

  bool get isOAuth => authType != 'pat';

  /// Connectable from this app today: an OAuth connector that has somewhere to
  /// wire the token.
  bool get supported => isOAuth && mcpReady;

  /// Title-case label from the code, so a connector added server-side shows up
  /// with a reasonable name and no app release.
  String get label => code
      .split(RegExp(r'[_-]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');

  /// Why this row is not actionable, or null when it is.
  String? get unsupportedReason {
    if (!isOAuth) return 'Needs a token pasted in — not supported here yet';
    if (!mcpReady) return 'No MCP server available for this app yet';
    return null;
  }

  static Connector fromJson(Map<String, dynamic> json) => Connector(
    code: (json['code'] ?? '').toString(),
    connected: (json['status'] ?? '') == 'connected',
    mcpReady: json['mcp_ready'] == true,
    authType: (json['auth_type'] ?? 'app').toString(),
    accountName: (json['account_name'] ?? '').toString(),
  );

  /// Parse `grid connector list --json`. Tolerates leading noise so a stray CLI
  /// warning line does not blank the whole screen.
  static List<Connector> parseList(String stdout) {
    final start = stdout.indexOf('[');
    if (start < 0) return const [];
    final decoded = jsonDecode(stdout.substring(start));
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(Connector.fromJson)
        .where((c) => c.code.isNotEmpty)
        .toList();
  }
}
