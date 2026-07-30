import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../shared/external_launch.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/connector_token.dart';
import 'connector_refresh_service.dart';
import 'connector_token_store.dart';
import 'connectors_refresh.dart';
import 'dcr_oauth_client.dart';
import 'mcp_auth_probe.dart';
import 'oauth_loopback_listener.dart';

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

  /// Link a server the user typed a URL for, with no gateway involved (path A).
  ///
  /// The app is the OAuth client here: it registers itself with the provider's
  /// authorization server (RFC 7591), runs authorization-code + PKCE S256, and
  /// catches the redirect on a loopback port (RFC 8252). [probe] is the discovery
  /// already done by the dialog, passed in rather than repeated — it decided this
  /// server can be driven at all.
  ///
  /// Ends in exactly the same place as [connect]: a `ConnectorToken` in the
  /// agent-neutral master store, projected into every agent. That is the whole
  /// point of doing this in the app rather than letting each agent register its
  /// own client — one consent, every agent.
  Future<String?> connectDirect({
    required String connector,
    required String mcpUrl,
    required McpAuthProbeResult probe,
  }) async {
    _cancelled = false;
    final oauth = ref.read(dcrOAuthClientProvider);
    final log = ref.read(appLogProvider);
    log.info(
      'connectors',
      'Direct sign-in for "$connector" at $mcpUrl — issuer ${probe.issuer}, '
          'registration ${probe.registrationEndpoint}',
    );

    // Bind before registering: the registration has to name the exact
    // `redirect_uri` the browser will come back to, port included.
    final OAuthLoopbackListener listener;
    try {
      listener = await OAuthLoopbackListener.bind();
    } on Object catch (error, stack) {
      log.failure(
        'connectors',
        'Binding the loopback listener failed',
        error: error,
        stackTrace: stack,
      );
      return "Couldn't open a local port to finish the sign-in: $error";
    }

    try {
      final (client, registerError) = await oauth.register(
        probe,
        redirectUri: listener.redirectUri,
      );
      if (client == null) {
        log.failure(
          'connectors',
          'Registering with ${probe.issuer} failed',
          error: registerError,
        );
        return registerError?.message ?? "Couldn't register with this server.";
      }
      log.info(
        'connectors',
        'Registered with ${probe.issuer} as ${client.clientId} '
            '(auth ${client.authMethod}, '
            'secret ${client.clientSecret == null ? 'none' : 'issued'}), '
            'redirect ${client.redirectUri}',
      );

      // Only now is the old credential dropped — same reasoning as [connect]:
      // clearing before we know the attempt can start breaks what worked.
      await _forgetLocally(connector);

      final pkce = PkcePair.create();
      final state0 = randomStateValue();
      state = ConnectorLinkState(
        pending: PendingLink(connector: connector, startedAt: DateTime.now()),
        message: 'Finish in your browser, then come back here.',
        subject: connector,
      );
      await openExternalUrl(
        oauth
            .authorizeUrl(
              client: client,
              probe: probe,
              pkce: pkce,
              state: state0,
            )
            .toString(),
      );

      final result = await listener.waitForCallback();
      if (_cancelled) return null;

      switch (result) {
        case LoopbackTimeout():
          log.warn('connectors', 'No callback arrived for "$connector"');
          return _settle(connector, 'The sign-in timed out. Try again.');
        case LoopbackDenied(isCancel: true):
          log.info('connectors', 'User cancelled the sign-in for "$connector"');
          return _settle(connector, 'Sign-in cancelled.');
        case LoopbackDenied(:final error, :final description):
          log.warn(
            'connectors',
            'Provider refused the sign-in for "$connector": $error '
                '$description',
          );
          return _settle(
            connector,
            description.isEmpty
                ? "That didn't work ($error). Try again."
                : "That didn't work: $description",
          );
        case LoopbackSuccess(:final code, state: final returned):
          // The app minted `state`, so the app is what checks it. A mismatch
          // means this callback belongs to a different request — possibly one
          // somebody else started — and the code must not be redeemed.
          if (returned != state0) {
            log.failure(
              'connectors',
              'State mismatch on the callback for "$connector" — the code was '
                  'not redeemed',
            );
            return _settle(
              connector,
              "That sign-in didn't match the one this app started. Try again.",
            );
          }
          final (token, exchangeError) = await oauth.exchange(
            client: client,
            probe: probe,
            pkce: pkce,
            code: code,
            connector: connector,
            mcpUrl: mcpUrl,
          );
          if (token == null) {
            log.failure(
              'connectors',
              'Exchanging the code for "$connector" failed',
              error: exchangeError,
            );
            return _settle(
              connector,
              exchangeError?.message ?? "Couldn't finish the sign-in.",
            );
          }
          log.info(
            'connectors',
            'Got a token for "$connector" '
                '(expires ${token.expiresAt}, '
                'refreshable ${token.canBeRefreshed}, '
                'mcp_entry ${token.mcpEntry == null ? 'none' : 'yes'})',
          );
          return _store(token);
      }
    } finally {
      // Whatever happened, the socket goes away. `waitForCallback` closes it on
      // its own paths; this covers the ones that never got there.
      await listener.close();
    }
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
    return _store(token);
  }

  /// Write a freshly obtained token down, hand it to the agents, and re-arm the
  /// renewal schedule.
  ///
  /// Shared by both paths on purpose: the gateway's one-shot `ready` and path A's
  /// token exchange are equally unrepeatable, so both need the same ordering —
  /// **disk first**, then state, then anything that could throw. Two copies of
  /// this ordering would be two chances to get it wrong.
  Future<String?> _store(ConnectorToken token) async {
    final connector = token.connector;
    final log = ref.read(appLogProvider);
    final store = ref.read(connectorTokenStoreProvider);
    try {
      await store.save(token);
      // Confirm by *reading back*, not by the write returning. A save that threw
      // nothing but landed somewhere unexpected — a different home, a path the
      // app can't actually reach — looks identical to success from here, and the
      // whole point of the master store is that every agent finds it later.
      final present = (await store.read()).containsKey(connector);
      log.record(
        present ? AppLogLevel.info : AppLogLevel.error,
        'connectors',
        present
            ? 'Stored "$connector" (${token.source.name}) in ${store.file.path}'
            : 'Wrote "$connector" to ${store.file.path} but it read back '
                  'missing — the master store did not take it',
      );
    } on Object catch (error, stack) {
      // The credential is gone now — it was a single delivery and the write
      // failed. Say so plainly rather than leaving a row that looks connected.
      log.failure(
        'connectors',
        'Saving "$connector" to ${store.file.path} failed',
        error: error,
        stackTrace: stack,
      );
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
  ///
  /// [removing] names connectors the caller has just deleted, and is the **only**
  /// way anything gets removed from an agent's config. Left empty — which is what
  /// every ordinary call passes — this adds and updates but never deletes, so a
  /// store that failed to load, or one connector's bad day, cannot take other
  /// connectors down with it.
  Future<String?> projectTokens({Set<String> removing = const {}}) async {
    final tool = ref.read(extensionAgentProvider);
    final log = ref.read(appLogProvider);
    final project = ref
        .read(agentExtensionsProvider(tool))
        ?.mcp
        ?.projectConnectorTokens;
    // A null projection is not an error: this agent has no concept of OAuth
    // connectors. The screen says so; it does not fail a save over it.
    if (project == null) {
      log.warn(
        'connectors',
        'Agent ${tool.name} has no connector projection — tokens stay in the '
            'master store only',
      );
      return null;
    }

    try {
      final store = ref.read(connectorTokenStoreProvider);
      final tokens = await store.read();
      // The count is the diagnostic that matters. Projecting *zero* tokens while
      // an agent's config ends up holding one means the two halves disagree
      // about where the truth lives — the exact split that hides a credential
      // from every agent but the current one.
      log.info(
        'connectors',
        'Projecting ${tokens.length} token(s) '
            '[${tokens.keys.join(', ')}] from ${store.file.path} '
            'into ${tool.name}'
            '${removing.isEmpty ? '' : ', removing [${removing.join(', ')}]'}',
      );
      await project(tokens.values.toList(), removing: removing);
    } on AgentExtensionException catch (error, stack) {
      log.failure(
        'connectors',
        'Projecting tokens into ${tool.name} failed',
        error: error,
        stackTrace: stack,
      );
      return error.message;
    } on Object catch (error, stack) {
      log.failure(
        'connectors',
        'Projecting tokens into ${tool.name} failed',
        error: error,
        stackTrace: stack,
      );
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
  ///
  /// Which endpoint renews it depends on who obtained it. A self-registered
  /// (path A) token is renewed here against the provider, using the `client_id`
  /// in `clients.json`; the gateway has never seen that credential and would
  /// answer about a connector it doesn't know. A gateway token is the reverse —
  /// renewing it locally is impossible, because the `client_secret` lives on the
  /// server by design.
  Future<String?> refresh(String connector) async {
    final stored = (await _readTokens())[connector];
    if (stored != null && stored.source == ConnectorTokenSource.dcr) {
      return _refreshDcr(stored);
    }

    final (token, error) = await ref
        .read(connectorGatewayClientProvider)
        .refresh(connector);
    if (token == null) {
      // A failed renewal **never deletes anything**. The stored entry holds the
      // `refresh_token`, which is the only thing that could still rescue this
      // connector — a later attempt, or the user reconnecting — and erasing it
      // over one bad answer throws that away for good.
      //
      // It also used to erase far more than itself: `_forgetLocally` re-projects
      // the *whole* store, so one expired connector rewrote every agent's config
      // from what was left. On 2026-07-30 a stale `asana` token took two
      // unrelated, working connectors out of `config.yaml` with it.
      if (error != null && error.isUnauthorized) {
        ref
            .read(appLogProvider)
            .warn(
              'connectors',
              'Gateway refused to renew "$connector" (401) — keeping the stored '
                  'credential so it can be retried or reconnected',
            );
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

  /// Renew a self-registered token against the provider itself.
  ///
  /// Kept beside the gateway path rather than in the refresh service, so both
  /// renewals end the same way — save, project, publish — and a caller never has
  /// to know which one ran.
  Future<String?> _refreshDcr(ConnectorToken stored) async {
    final (renewed, error) = await ref
        .read(dcrOAuthClientProvider)
        .refresh(stored, issuer: stored.issuer);
    if (renewed == null) {
      // Same rule as the gateway path: a refusal is not a reason to delete. The
      // `refresh_token` stays on disk, so a transient failure costs nothing and
      // a real revocation still ends with the user reconnecting — which
      // overwrites this entry anyway.
      ref
          .read(appLogProvider)
          .warn(
            'connectors',
            'Provider refused to renew "${stored.connector}" — keeping the '
                'stored credential',
            error: error,
          );
      return error?.message ??
          'That connection expired. Connect it again to keep using it.';
    }

    try {
      await ref.read(connectorTokenStoreProvider).save(renewed);
    } on Object catch (failure) {
      return "Couldn't save the refreshed connection: $failure";
    }
    final projectionError = await projectTokens();
    _publishTokens();
    return projectionError;
  }

  Future<Map<String, ConnectorToken>> _readTokens() async {
    try {
      return await ref.read(connectorTokenStoreProvider).read();
    } on Object {
      return const {};
    }
  }

  /// Disconnect at the gateway, then locally.
  ///
  /// Server first: if that fails, the machine still holds a working token
  /// rather than a broken half-state. This does **not** revoke access at the
  /// provider — only the user can, in the provider's own settings — and the
  /// confirmation dialog has to say so.
  ///
  /// A self-registered connector has no server side to call: the gateway never
  /// held that credential, so forgetting the local copy *is* the whole
  /// disconnect. The registration in `clients.json` is deliberately **kept** —
  /// dropping it would mint a new `client_id` on the next connect and leave a
  /// dead app entry behind in the user's account at the provider, one per
  /// sign-in.
  Future<String?> disconnect(String connector) async {
    final stored = (await _readTokens())[connector];
    if (stored != null && stored.source == ConnectorTokenSource.dcr) {
      await _forgetLocally(connector);
      return null;
    }

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

  /// Drop this machine's copy of [connector] and re-project so the agents lose
  /// it too.
  ///
  /// It is the only place that names a connector in `removing`, which is what
  /// keeps a deletion scoped to the one connector being forgotten. Every other
  /// caller of [projectTokens] adds and updates without removing anything.
  ///
  /// Logged with a **stack trace even on success**, which is unusual and
  /// deliberate: this is the only code that deletes a stored credential, and it
  /// is reached from several places — a fresh Connect clearing the old token, a
  /// disconnect. When a token goes missing, "which caller erased it" is the
  /// entire question, and the answer is otherwise unrecoverable after the fact.
  Future<void> _forgetLocally(String connector) async {
    final log = ref.read(appLogProvider);
    try {
      final store = ref.read(connectorTokenStoreProvider);
      final had = (await store.read()).containsKey(connector);
      await store.remove(connector);
      if (had) {
        log.record(
          AppLogLevel.warn,
          'connectors',
          'Forgetting local token for "$connector"',
          stackTrace: StackTrace.current,
        );
      }
    } on Object catch (error, stack) {
      // The re-projection below is what actually stops the agent using it, and
      // that runs regardless — but a failure here leaves a credential on disk
      // that the user believes is gone, which is worth saying out loud.
      log.failure(
        'connectors',
        'Removing the local token for "$connector" failed',
        error: error,
        stackTrace: stack,
      );
    }
    await projectTokens(removing: {connector});
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
