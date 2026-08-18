import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../shared/external_launch.dart';
import '../../agents/logic/adapters/claude_tool.dart';
import '../../agents/logic/adapters/codex_tool.dart';
import '../../agents/logic/adapters/hermes_tool.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/agent_extensions_registry.dart';
import '../../agents/logic/connector_token.dart';
import '../../agents/logic/mcp_server.dart';
import 'connector_catalog.dart';
import 'connectors_controller.dart';
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

/// How a sign-in ended.
///
/// Exists because `connect` had no way to say. It returned a `String?` where
/// null meant "the row explains this itself" — which lumped a finished sign-in,
/// a browser the user closed, and a timeout into one value, and left the caller
/// re-reading the token store to guess which had happened. Three outcomes the
/// user should hear about differently cannot share one null.
enum ConnectorLinkOutcome {
  /// A credential landed on this machine.
  connected,

  /// The user stopped waiting. Nothing on disk changed.
  cancelled,

  /// It didn't work. The row is already showing why.
  failed,

  /// It never got off the ground — the gateway refused the start. Worth saying
  /// out loud, because there is no row state for something that never began.
  notStarted,
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

  /// The loopback listener for a path-A sign-in that is currently waiting.
  ///
  /// Held only so [cancel] can end the wait — see the note there. Null on the
  /// gateway path, which polls on a timer this flag already interrupts, and
  /// cleared as soon as the direct path is done with its socket.
  OAuthLoopbackListener? _listener;

  @override
  ConnectorLinkState build() => const ConnectorLinkState();

  /// Link [connector]: start, open the browser, poll, store, project.
  ///
  /// Returns how it ended, plus a line worth showing when there is one. The
  /// outcome is decided here rather than threaded back through the poll loop, so
  /// the two paths that share [_store] — this one and path A — keep their
  /// existing contract untouched.
  Future<(ConnectorLinkOutcome, String?)> connect(String connector) async {
    _cancelled = false;
    final client = ref.read(connectorGatewayClientProvider);

    // Start first, clear second. Clearing a working connector before knowing
    // the new attempt can even begin would break something that worked, over a
    // dropped network or a mistyped connector code.
    final (authorization, startError) = await client.start(connector);
    if (authorization == null) {
      return (
        ConnectorLinkOutcome.notStarted,
        startError?.message ?? "Couldn't start the sign-in.",
      );
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

    final problem = await _awaitPickup(authorization);
    // The browser has stopped being where the answer is. Raising Grid is what
    // "close the browser when it's done" can actually deliver: a page cannot
    // shut a tab a script didn't open, and this path doesn't even serve the
    // final page — the gateway does — so there is nothing here to attach a
    // close attempt to. Unconditional, because a cancel or a timeout is a
    // result the user needs to come back and read too.
    await bringAppToFront();
    // Cancel first: the user's own choice outranks whatever the loop was in the
    // middle of when they made it.
    if (_cancelled) return (ConnectorLinkOutcome.cancelled, null);

    // The honest test for success, and the reason it is a *read*: the poll loop
    // reports failures through the row's message and returns null for all of
    // them, so the only thing that separates a finished sign-in from a timeout
    // is whether a credential is now on disk.
    final store = ref.read(connectorTokenStoreProvider);
    final linked = (await store.read()).containsKey(connector);
    return (
      linked ? ConnectorLinkOutcome.connected : ConnectorLinkOutcome.failed,
      problem,
    );
  }

  /// Link a catalog row by whichever route its connector supports.
  ///
  /// The one entry point the Connect button calls, so the widget never has to
  /// know which path a connector is on — and so the two paths cannot drift into
  /// different toasts, spinners or cancel behaviour for the same button.
  ///
  /// A self-serve entry ([ConnectorCatalogEntry.isSelfServe]) is probed first,
  /// and **the probe is what decides** what happens next — not the catalog. The
  /// bundled list is a file in the binary and a gateway `auth_type` is a config
  /// row somebody typed; both are claims about a server that may have changed
  /// its mind since. So `dcr` and `open` take the same route here, and the
  /// server's own answer picks the ending:
  ///
  /// - **dynamic registration** → path A: register, authorize, store a token.
  /// - **open** → write the MCP entry and stop. No browser, no credential.
  /// - anything else → say so, without opening a browser the user would then
  ///   have to close.
  ///
  /// That an entry declared `dcr` can end up adopted as open (or the reverse)
  /// is the point rather than an accident: a server that drops its sign-in
  /// should still connect, and one that adds a sign-in should still ask for it.
  Future<(ConnectorLinkOutcome, String?)> connectCatalog(
    ConnectorCatalogEntry entry,
  ) async {
    if (!entry.isSelfServe) return connect(entry.code);

    final connector = entry.code;
    final mcpUrl = entry.mcpUrl;
    if (mcpUrl.isEmpty) {
      return (
        ConnectorLinkOutcome.notStarted,
        'This connector has no server address to sign into.',
      );
    }

    _cancelled = false;
    // The row enters its waiting state *before* the probe, not after. Discovery
    // is three round trips and allows twelve seconds each, and a Connect that
    // sat silent that long before the browser appeared reads as a button that
    // did nothing. It also puts Cancel on the row, which is the only way out
    // while the probe is in flight.
    state = ConnectorLinkState(
      pending: PendingLink(connector: connector, startedAt: DateTime.now()),
      message: 'Checking how this server signs in…',
      subject: connector,
    );

    final probe = await ref.read(mcpAuthProbeProvider).probe(mcpUrl);
    // Tested here rather than left to [connectDirect], which clears the flag on
    // entry: a cancel during the probe would otherwise be forgotten, and the
    // browser would open after the user had already backed out.
    if (_cancelled) return (ConnectorLinkOutcome.cancelled, null);

    ref
        .read(appLogProvider)
        .info(
          'connectors',
          'Probed catalog connector "$connector" at $mcpUrl → '
              '${probe.kind.name} '
              '(issuer ${probe.issuer.isEmpty ? '—' : probe.issuer})',
        );

    switch (probe.kind) {
      case McpAuthKind.dynamicRegistration:
        break; // the sign-in below
      case McpAuthKind.open:
        return _adoptOpen(connector, mcpUrl);
      case McpAuthKind.preRegistered:
      case McpAuthKind.manual:
      case McpAuthKind.unreachable:
        // Left on the row rather than flashed as a toast: the catalog offered
        // this connector and its own server disagreed, which is a standing fact
        // about the row until something changes.
        return (
          ConnectorLinkOutcome.failed,
          _settle(connector, _cannotDrive(probe)),
        );
    }

    final error = await connectDirect(
      connector: connector,
      mcpUrl: mcpUrl,
      probe: probe,
    );
    if (_cancelled) return (ConnectorLinkOutcome.cancelled, null);

    // The same test [connect] makes, for the same reason: path A reports its
    // failures through the row's message and returns null for most of them, so
    // the only honest answer to "did that work" is whether a credential is now
    // on disk.
    final linked = (await _readTokens()).containsKey(connector);
    return (
      linked ? ConnectorLinkOutcome.connected : ConnectorLinkOutcome.failed,
      error,
    );
  }

  /// Take on a server that asks for nothing: write the MCP entry, and stop.
  ///
  /// Nothing reaches `tokens.json`, because there is no credential to put
  /// there. That has consequences worth stating, and all of them are the ones
  /// we want: the row afterwards is an ordinary configured server — Edit and
  /// Remove rather than a "Signed in" tag — removing it is the manual store's
  /// own delete, and the refresh sweep never looks at it because there is
  /// nothing to expire.
  Future<(ConnectorLinkOutcome, String?)> _adoptOpen(
    String connector,
    String mcpUrl,
  ) async {
    ref
        .read(appLogProvider)
        .info(
          'connectors',
          'Adopting "$connector" at $mcpUrl as an open server — no credential',
        );
    final error = await ref
        .read(mcpServersProvider.notifier)
        .save(
          McpServer(
            name: connector,
            transport: McpHttp(url: mcpUrl),
          ),
        );
    // Clears the waiting state the probe put up. There is no browser round trip
    // on this path, so nothing else would.
    state = const ConnectorLinkState();
    return error == null
        ? (ConnectorLinkOutcome.connected, null)
        : (ConnectorLinkOutcome.failed, error);
  }

  /// Why a connector the catalog offered turned out not to be drivable here.
  ///
  /// One line per outcome the probe can reach, each naming what the user can do
  /// instead. The two kinds the caller has already handled are listed only to
  /// keep the switch exhaustive, so a new probe result cannot be added without
  /// deciding what this says about it.
  String _cannotDrive(McpAuthProbeResult probe) => switch (probe.kind) {
    McpAuthKind.preRegistered =>
      'This server needs Grid to register an app first — not available yet.',
    McpAuthKind.manual || McpAuthKind.unreachable =>
      probe.detail.isEmpty
          ? "This server's sign-in could not be read. Try again later."
          : probe.detail,
    McpAuthKind.dynamicRegistration || McpAuthKind.open => '',
  };

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
    // Published before the first await below, so a Cancel arriving at any point
    // from here on finds something to abort.
    _listener = listener;

    try {
      final (client, registerError) = await oauth.register(
        probe,
        redirectUris: listener.redirectUris,
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
      // Same reason as the gateway path above. Here the served page has also
      // asked the tab to close itself, so on the browsers that allow it the two
      // land together: the tab goes, Grid comes forward.
      await bringAppToFront();
      if (_cancelled) return null;

      switch (result) {
        case LoopbackAborted():
          // Say nothing on the row. The user pressed Cancel; `cancel()` has
          // already cleared the state, and settling a message here would put a
          // note back on a row they just finished with.
          log.info('connectors', 'Sign-in for "$connector" cancelled here');
          return null;
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
      // Cleared first: a Cancel landing after this point has nothing left to
      // abort, and leaving a closed listener published would have `cancel`
      // reach into a finished sign-in.
      if (identical(_listener, listener)) _listener = null;
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

  /// Write every stored token into **every installed agent's** own format.
  ///
  /// Called after any change to the master store. Idempotent by contract, so
  /// calling it when in doubt is cheap.
  ///
  /// [removing] names connectors the caller has just deleted, and is the **only**
  /// way anything gets removed from an agent's config. Left empty — which is what
  /// every ordinary call passes — this adds and updates but never deletes, so a
  /// store that failed to load, or one connector's bad day, cannot take other
  /// connectors down with it.
  ///
  /// **Fans out across agents, rather than writing only to the selected one.**
  /// It used to project into `extensionAgentProvider` alone, and that quietly
  /// broke the promise D10 exists to make. Nothing calls this when the *agent*
  /// changes — every caller is a token-store event (connect, disconnect,
  /// refresh) — so a connector only ever reached whichever agent happened to be
  /// selected at the moment it was linked. Measured on 2026-08-03: ten
  /// connectors linked under Hermes, then Claude Code selected, and
  /// `~/.claude.json` still had no `mcpServers` at all. "Sign in once, every
  /// agent can use it" was true for exactly one agent.
  ///
  /// Two guards keep the fan-out from being intrusive, both from §D21:
  ///
  /// - **Installed agents only.** Creating a config file for a program the user
  ///   has never opened is not this app's business.
  /// - **Errors are collected per agent, never thrown.** One agent's broken
  ///   config must not stop the others from being written — the whole point of
  ///   fanning out is that the connector lands everywhere it can.
  Future<String?> projectTokens({Set<String> removing = const {}}) async {
    final log = ref.read(appLogProvider);

    final store = ref.read(connectorTokenStoreProvider);
    // Read once, not per agent: three reads of the same file could disagree if
    // a refresh lands mid-fan-out, and then two agents would hold different
    // ideas of the same connector.
    final Map<String, ConnectorToken> tokens;
    try {
      tokens = await store.read();
    } on Object catch (error, stack) {
      log.failure(
        'connectors',
        'Reading the token store failed — nothing projected',
        error: error,
        stackTrace: stack,
      );
      return "Couldn't read the stored connectors: $error";
    }

    final targets =
        <
          AgentTool,
          Future<void> Function(
            List<ConnectorToken> tokens, {
            Set<String> removing,
          })
        >{};
    for (final tool in AgentTool.values) {
      if (!_isInstalled(tool)) continue;
      final project = ref
          .read(agentExtensionsProvider(tool))
          ?.mcp
          ?.projectConnectorTokens;
      // A null projection is not an error: this agent has no concept of OAuth
      // connectors. The screen says so; it does not fail a save over it.
      if (project != null) targets[tool] = project;
    }

    if (targets.isEmpty) {
      log.warn(
        'connectors',
        'No installed agent can take a connector projection — tokens stay in '
            'the master store only',
      );
      return null;
    }

    // The count is the diagnostic that matters. Projecting *zero* tokens while
    // an agent's config ends up holding one means the two halves disagree
    // about where the truth lives — the exact split that hides a credential
    // from every agent but the current one.
    log.info(
      'connectors',
      'Projecting ${tokens.length} token(s) '
          '[${tokens.keys.join(', ')}] from ${store.file.path} '
          'into ${targets.keys.map((t) => t.name).join(', ')}'
          '${removing.isEmpty ? '' : ', removing [${removing.join(', ')}]'}',
    );

    final values = tokens.values.toList();
    final failures = <String>[];
    for (final entry in targets.entries) {
      try {
        await entry.value(values, removing: removing);
      } on AgentExtensionException catch (error, stack) {
        log.failure(
          'connectors',
          'Projecting tokens into ${entry.key.name} failed',
          error: error,
          stackTrace: stack,
        );
        failures.add('${entry.key.name}: ${error.message}');
      } on Object catch (error, stack) {
        log.failure(
          'connectors',
          'Projecting tokens into ${entry.key.name} failed',
          error: error,
          stackTrace: stack,
        );
        failures.add('${entry.key.name}: $error');
      }
    }

    // The projection just rewrote the agents' `mcp_servers`, which the screen
    // reads separately from the tokens. Refreshed here rather than at each
    // caller, because this is the only place that knows the config moved. Run
    // even when an agent failed — the ones that succeeded did move.
    refreshConnectors(ref);

    if (failures.isEmpty) return null;
    // Named per agent. "Couldn't hand the connector to the agent" was fine when
    // there was one; with three it hides which config to go and look at.
    return failures.length == 1
        ? "Couldn't hand the connectors to ${failures.single}"
        : "Couldn't hand the connectors to some agents — ${failures.join('; ')}";
  }

  /// Whether [tool]'s binary is on this machine.
  ///
  /// Presence of the binary, not of a config file: an agent that is installed
  /// but has never been run has no config yet, and that is exactly the case
  /// where writing one is useful rather than intrusive.
  bool _isInstalled(AgentTool tool) => switch (tool) {
    AgentTool.hermes => ref.read(hermesInstalledProvider),
    AgentTool.codex => ref.read(codexInstalledProvider),
    AgentTool.claude => ref.read(claudeInstalledProvider),
  };

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
      await ref.read(connectorTokenStoreProvider).saveRefreshed(token);
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
      await ref.read(connectorTokenStoreProvider).saveRefreshed(renewed);
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
  ///
  /// **Aborts the loopback wait too, and that is the whole fix.** Clearing the
  /// state alone made the row *look* cancelled — the Cancel button belongs to
  /// `isPending` — while `connectDirect` stayed parked on `waitForCallback` for
  /// up to five minutes. The row fell back to `_busy`, which only the connect
  /// path clears, and rendered a bare spinner with no button: the reported bug.
  void cancel() {
    _cancelled = true;
    _listener?.abort();
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
