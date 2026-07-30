import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';
import '../../../shared/external_launch.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/connector_token.dart';
import 'connector_refresh_service.dart';
import 'connector_token_store.dart';
import 'connectors_refresh.dart';

/// A connector the app is waiting on, held in memory only.
///
/// Deliberately not persisted: a half-finished authorization is worth nothing
/// after a restart, and the `pickup_code` in it would be a dead handle.
class PendingLink {
  const PendingLink({required this.connector, required this.startedAt});

  final String connector;
  final DateTime startedAt;
}

/// What the screen shows about a link in progress.
class ConnectorLinkState {
  const ConnectorLinkState({
    this.pending,
    this.message = '',
    this.subject = '',
  });

  /// The connector waiting on a browser, if any. At most one at a time.
  final PendingLink? pending;

  /// A quiet line for the row — what it's waiting for, or how the last attempt
  /// ended. Not a toast: cancelling a sign-in is not an event worth
  /// interrupting anyone over.
  final String message;

  /// Which connector [message] belongs to.
  final String subject;

  bool isPending(String connector) => pending?.connector == connector;

  String messageFor(String connector) => subject == connector ? message : '';
}

/// Drives one connector from "Connect" to a token the agent can use.
///
/// The gateway owns the OAuth exchange entirely: it mints `state`, holds every
/// `client_id`/`client_secret`, swaps the provider's code for a token
/// server-side, and renders the MCP entry. Nothing comes back to this app from
/// the browser — no deep link, no callback — so the flow is: start, open the
/// browser, then **poll** until the answer appears.
///
/// What is genuinely ours is the last two steps: getting the token onto this
/// machine and into the agent's own config. That is what keeps Grid local — the
/// gateway brokers the handshake once, and every tool call afterwards goes
/// straight from this computer to the provider.
class ConnectorLinkController extends Notifier<ConnectorLinkState> {
  /// Set while a poll loop is running, so a cancel (or a second Connect) can
  /// stop it without waiting out the interval.
  bool _cancelled = false;

  @override
  ConnectorLinkState build() => const ConnectorLinkState();

  /// Link [connector]: start, open the browser, poll, store, project.
  ///
  /// Returns null when the outcome is something the row explains itself, or a
  /// line for the caller to show — reserved for failures to *start*, since
  /// everything after the browser opens is the row's own business.
  Future<String?> connect(String connector) async {
    _cancelled = false;
    final client = ref.read(connectorGatewayClientProvider);

    // Start first, clear second. Clearing a working connector before knowing
    // the new attempt can even begin would break something that worked, over a
    // dropped network or a mistyped connector code.
    final (authorization, startError) = await client.start(connector);
    if (authorization == null) {
      return startError?.message ?? "Couldn't start the sign-in.";
    }

    // Now the old credential must stop working: the user is deliberately
    // replacing it, and a stale token left in an agent's config would go on
    // being used until it expired.
    await _forgetLocally(connector);

    state = ConnectorLinkState(
      pending: PendingLink(connector: connector, startedAt: DateTime.now()),
      message: 'Finish in your browser, then come back here.',
      subject: connector,
    );
    await openExternalUrl(authorization.authorizeUrl);

    return _awaitPickup(authorization);
  }

  /// Poll until the gateway has an answer, the clock runs out, or the user
  /// cancels.
  Future<String?> _awaitPickup(ConnectorAuthorization authorization) async {
    final client = ref.read(connectorGatewayClientProvider);
    final connector = authorization.connector;
    final deadline = DateTime.now().add(authorization.expiresIn);

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(authorization.pollInterval);
      if (_cancelled) return null;

      final (result, error) = await client.poll(
        authorization.pickupCode,
        connector: connector,
      );
      if (_cancelled) return null;

      if (result == null) {
        // One failed poll is not the end — networks hiccup, and the
        // authorization is still live at the server. Only a dead session is
        // worth giving up over.
        if (error != null && error.isUnauthorized) {
          return _settle(connector, error.message);
        }
        continue;
      }

      switch (result.status) {
        case ConnectorPollStatus.pending:
          continue;

        case ConnectorPollStatus.ready:
          return _adopt(result);

        case ConnectorPollStatus.failed:
          return _settle(
            connector,
            result.error.isEmpty
                ? "That didn't work. Try connecting again."
                : "That didn't work: ${result.error}",
          );

        case ConnectorPollStatus.expired:
          return _settle(connector, 'The sign-in expired. Try again.');

        case ConnectorPollStatus.consumed:
          // Only reachable if we polled after already collecting a ready — a
          // bug on this side, and nothing the user can act on.
          return _settle(connector, 'That sign-in was already completed.');
      }
    }

    return _settle(connector, 'The sign-in timed out. Try again.');
  }

  /// Take delivery of the one and only `ready`.
  ///
  /// Order matters more here than anywhere else in this flow: the token arrives
  /// exactly once, and polling again returns `consumed` with nothing in it. So
  /// the write to disk happens before the state changes, before any toast, and
  /// before anything else that could throw.
  Future<String?> _adopt(ConnectorPollResult result) async {
    final token = result.token;
    final connector = result.connector;
    if (token == null) {
      return _settle(
        connector,
        'The sign-in finished but no credential came back. Try again.',
      );
    }

    try {
      await ref.read(connectorTokenStoreProvider).save(token);
    } on Object catch (error) {
      // The token is gone now — it was a one-shot delivery and the write
      // failed. Say so plainly rather than leaving a row that looks connected.
      return _settle(
        connector,
        "Couldn't save the connection ($error). Try connecting again.",
      );
    }

    final projectionError = await projectTokens();
    _publishTokens();
    state = const ConnectorLinkState();

    // Re-arm the refresh schedule around the token that just arrived. Without
    // this the service is still asleep on the old deadline — or on no deadline
    // at all, if this is the first connector — and the new credential would
    // lapse with nothing watching it.
    unawaited(ref.read(connectorRefreshServiceProvider).start());

    if (projectionError != null) return projectionError;
    // Signed in, and the gateway has no MCP server behind this connector yet:
    // the account really is linked, the agent just gains no tool from it. Said
    // plainly, because a bare checkmark would promise a tool that isn't there.
    if (!token.isUsable) {
      return _settle(
        connector,
        "Connected. The agent can't use it yet — tools are coming.",
      );
    }
    return null;
  }

  /// Write every stored token into the selected agent's own format.
  ///
  /// Called after any change to the master store. Idempotent by contract, so
  /// calling it when in doubt is cheap.
  Future<String?> projectTokens() async {
    final tool = ref.read(extensionAgentProvider);
    final project = ref
        .read(agentExtensionsProvider(tool))
        ?.mcp
        ?.projectConnectorTokens;
    // A null projection is not an error: this agent has no concept of OAuth
    // connectors. The screen says so; it does not fail a save over it.
    if (project == null) return null;

    try {
      final tokens = await ref.read(connectorTokenStoreProvider).read();
      await project(tokens.values.toList());
    } on AgentExtensionException catch (error) {
      return error.message;
    } on Object catch (error) {
      return "Couldn't hand the connector tokens to the agent: $error";
    }
    // The projection just rewrote the agent's `mcp_servers`, which the screen
    // reads separately from the tokens. Refreshed here rather than at each
    // caller, because this is the only place that knows the config moved.
    refreshConnectors(ref);
    return null;
  }

  /// Renew a token that is close to expiring, then re-project it.
  ///
  /// A refreshed token that never reaches the agent's config is worse than
  /// useless: the agent goes on using the dead one.
  Future<String?> refresh(String connector) async {
    final (token, error) = await ref
        .read(connectorGatewayClientProvider)
        .refresh(connector);
    if (token == null) {
      // 401 means the provider revoked it and the server has already dropped
      // the credential — no retry helps, the user must reconnect.
      if (error != null && error.isUnauthorized) {
        await _forgetLocally(connector);
        return 'That connection expired. Connect it again to keep using it.';
      }
      return error?.message ?? "Couldn't refresh the connection.";
    }

    try {
      await ref.read(connectorTokenStoreProvider).save(token);
    } on Object catch (failure) {
      return "Couldn't save the refreshed connection: $failure";
    }
    final projectionError = await projectTokens();
    // A refreshed token carries a new expiry, and the row shows it. Nothing
    // else on this path touches the state, so without this the screen keeps
    // reporting the old one.
    _publishTokens();
    return projectionError;
  }

  /// Disconnect at the gateway, then locally.
  ///
  /// Server first: if that fails, the machine still holds a working token
  /// rather than a broken half-state. This does **not** revoke access at the
  /// provider — only the user can, in the provider's own settings — and the
  /// confirmation dialog has to say so.
  Future<String?> disconnect(String connector) async {
    final (ok, error) = await ref
        .read(connectorGatewayClientProvider)
        .disconnect(connector);
    if (!ok) return error?.message ?? "Couldn't disconnect.";

    await _forgetLocally(connector);
    return null;
  }

  /// Stop waiting. The user may still finish in the browser; that result simply
  /// goes uncollected, and the next Connect starts a fresh authorization.
  void cancel() {
    _cancelled = true;
    state = const ConnectorLinkState();
  }

  Future<void> _forgetLocally(String connector) async {
    try {
      await ref.read(connectorTokenStoreProvider).remove(connector);
    } on Object {
      // Nothing to do here: the re-projection below is what actually stops the
      // agent using it, and that runs regardless.
    }
    await projectTokens();
    _publishTokens();
  }

  /// Re-read the whole screen after a write.
  ///
  /// A file write is invisible to Riverpod — nothing recomputes until something
  /// it watches changes — so every mutation here has to say so explicitly. It
  /// says so through the shared [refreshConnectors] rather than naming the
  /// providers it thinks it touched: this controller changes tokens, the agent's
  /// config *and* the connector's status at the gateway, and picking a subset is
  /// how a disconnected row went on reading Connected.
  void _publishTokens() => refreshConnectors(ref);

  String? _settle(String connector, String message) {
    state = ConnectorLinkState(message: message, subject: connector);
    return null;
  }
}

final connectorLinkControllerProvider =
    NotifierProvider<ConnectorLinkController, ConnectorLinkState>(
      ConnectorLinkController.new,
    );

/// The connector tokens this machine holds, keyed by connector code.
///
/// This — not the gateway's `status` field — is what makes a row read as
/// connected: the gateway knows the *account* is linked, possibly from another
/// computer, while this says the credential is actually here (D6).
final connectorTokensProvider = FutureProvider<Map<String, ConnectorToken>>((
  ref,
) {
  // Deliberately does **not** watch the link controller. It used to, as a way
  // of re-reading after a sign-in — but that made the controller a dependency
  // of this provider, so the controller invalidating it was a provider
  // depending on itself, and Riverpod threw `CircularDependencyError` on the
  // first Connect. The controller now invalidates this explicitly after every
  // write, which is both the fix and the clearer contract: the store changed
  // because somebody changed it, not because an unrelated state object moved.
  return ref.watch(connectorTokenStoreProvider).read();
});
