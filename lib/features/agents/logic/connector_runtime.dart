import 'connector_token.dart';
import 'rest_entry.dart';
import 'rest_entry_fallback.dart';

/// How this build will actually reach [token]'s provider.
///
/// One function, consulted by everything — the projection deciding whether to
/// write a config entry, the bridge deciding what to serve, the screen deciding
/// what to say. Three callers agreeing by construction rather than by three
/// similar-looking conditions is the whole point; the last time this question
/// was answered in more than one place, a connector was linked in the app and
/// absent from the agent at the same time.
///
/// **The gateway decides, the app obeys.** Only the gateway knows both what the
/// account granted and what the provider's MCP server demands, so a declared
/// [ConnectorToken.declaredTransport] wins outright — including
/// [ConnectorTransport.none], which suppresses the inference below. The app
/// deliberately performs no scope arithmetic of its own: the day Google changes
/// what `gmailmcp` accepts, that is a server-side row and not a release.
///
/// Inference runs only when the gateway said nothing, which is every token
/// written before the field existed.
ConnectorTransport effectiveTransport(ConnectorToken token) {
  final rest = effectiveRestEntry(token);
  switch (token.declaredTransport) {
    case ConnectorTransport.mcp:
      // Honoured only if an entry actually came with it. A declaration the
      // payload does not back up is a backend bug, and obeying it would put a
      // server with no URL into someone's config.
      if (token.mcpEntry != null) return ConnectorTransport.mcp;
    case ConnectorTransport.rest:
      if (rest != null) return ConnectorTransport.rest;
    case ConnectorTransport.none:
      return ConnectorTransport.none;
    case null:
      break;
  }
  if (token.mcpEntry != null) return ConnectorTransport.mcp;
  if (rest != null) return ConnectorTransport.rest;
  return ConnectorTransport.none;
}

/// The REST surface to serve for [token] — the gateway's, or the local stand-in.
///
/// The order is the point: a gateway payload silently supersedes the fallback,
/// so `rest_entry_fallback.dart` stops being consulted the moment the backend
/// ships without anyone flipping anything.
RestEntry? effectiveRestEntry(ConnectorToken token) =>
    token.restEntry ?? restEntryFallbackFor(token.connector);
