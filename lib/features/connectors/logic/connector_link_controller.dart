import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';
import '../../../shared/external_launch.dart';
import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/connector_token.dart';
import '../../auth/logic/session_controller.dart';
import 'connector_token_store.dart';
import 'oauth_loopback_listener.dart';

/// The `device_type` the gateway knows Grid desktop by.
///
/// The web's table runs `"11"`–`"14"` (Intern, InternCloud, Lamp, InternPro);
/// Grid desktop is newer than all of them and needs its own. **The value below
/// is a placeholder until the backend assigns one** — see §11 of the spec. On
/// the wire it is always a string, which is why it's typed as one here rather
/// than as an int that gets stringified at three different call sites.
const String kGridDesktopDeviceType = '15';

/// How long the app waits on the browser before it stops expecting an answer.
///
/// Comfortably inside the gateway's ~10 minute session TTL, so giving up here
/// never races the server: if the user finishes late the backend still records
/// it, and the next poll picks the connector up as `connecting`.
const Duration kLinkPendingTimeout = Duration(minutes: 5);

/// How often a settling connector is re-checked while the screen is open.
/// Matches the web client's cadence — the same backend, the same transition.
const Duration kConnectorPollInterval = Duration(seconds: 4);

/// A link the app is waiting on. In memory only, and deliberately so: a
/// half-finished authorization is not state worth surviving a restart, and
/// persisting it would leave handles on disk that no longer mean anything.
class PendingLink {
  const PendingLink({required this.connector, required this.startedAt});

  final String connector;
  final DateTime startedAt;
}

/// What the screen shows about a link the user is in the middle of.
class ConnectorLinkState {
  const ConnectorLinkState({this.pending, this.message = '', this.failed = ''});

  /// The connector currently waiting on a browser, if any. At most one — a
  /// second Connect closes the first, because two live `state` values invite
  /// matching the wrong one.
  final PendingLink? pending;

  /// A quiet line for the row: "Waiting for your browser…", or what happened
  /// when a link ended without connecting. Not a toast — cancelling is not an
  /// event worth interrupting anyone over.
  final String message;

  /// The connector the [message] belongs to, empty when it's about [pending].
  final String failed;

  bool isPending(String connector) => pending?.connector == connector;
}

/// Drives one connector from "Connect" to a token the agent can use.
///
/// The whole OAuth exchange belongs to the gateway: it mints `state`, holds
/// every `client_id` and `client_secret`, and swaps the provider's code for a
/// token server-side. This controller only opens a browser, catches the
/// callback on a loopback port, asks the gateway to finalize, and then does the
/// part that is genuinely ours — bringing the token down to this machine and
/// handing it to the agent.
///
/// That last step is what keeps Grid local. The gateway brokers the handshake
/// once; every tool call afterwards goes straight from this computer to the
/// provider, with no server of ours in the path.
class ConnectorLinkController extends Notifier<ConnectorLinkState> {
  OAuthLoopbackListener? _listener;

  @override
  ConnectorLinkState build() {
    ref.onDispose(() => _listener?.close());
    return const ConnectorLinkState();
  }

  /// Start linking [connector]. Returns null when the flow ended in a state the
  /// row can explain itself, or a line for the caller to show.
  ///
  /// The order matters: the listener binds *first*, because its port is part of
  /// the `redirect_uri` the gateway has to be told about. Asking the gateway
  /// first would mean guessing a port, and a guess that collides is a link that
  /// silently never completes.
  Future<String?> connect(String connector) async {
    final device = ref.read(selectedNetworkProvider);
    if (device == null || device.deviceId.isEmpty) {
      return 'Sign in to a grid first — a connector is linked to your account.';
    }

    await _cancelPending();

    final OAuthLoopbackListener listener;
    try {
      listener = await OAuthLoopbackListener.bind();
    } on Object catch (error) {
      return "Couldn't open a local port to finish the sign-in: $error";
    }
    _listener = listener;

    final client = ref.read(connectorGatewayClientProvider);
    final (grant, error) = await client.authorize(
      connector: connector,
      deviceId: device.deviceId,
      deviceType: kGridDesktopDeviceType,
      redirectUri: listener.redirectUri,
    );
    if (grant == null) {
      await _clearListener();
      return error?.message ?? "Couldn't start the sign-in.";
    }

    state = ConnectorLinkState(
      pending: PendingLink(connector: connector, startedAt: DateTime.now()),
      message: 'Waiting for your browser…',
    );
    await openExternalUrl(grant.authorizeUrl);

    final result = await listener.waitForCallback(timeout: kLinkPendingTimeout);
    _listener = null;

    return switch (result) {
      LoopbackSuccess(:final code, :final state) => await _finalize(
        connector,
        code: code,
        state: state,
      ),
      // Deny is not a failure. The row goes back to where it was with one quiet
      // line — wiring this into the same red toast as a network error would
      // teach the user that changing their mind broke something.
      LoopbackDenied(isCancel: true) => _settle(
        connector,
        'Sign-in cancelled.',
      ),
      LoopbackDenied(:final description, :final error) => _settle(
        connector,
        description.isNotEmpty ? description : "Sign-in failed: $error.",
      ),
      LoopbackTimeout() => _settle(
        connector,
        'The sign-in timed out. If you finished in the browser, this will '
        'catch up on its own.',
      ),
    };
  }

  /// Finish a link the gateway accepted: pull the token down, store it, hand it
  /// to the agent.
  Future<String?> _finalize(
    String connector, {
    required String code,
    required String state,
  }) async {
    final client = ref.read(connectorGatewayClientProvider);
    // `state` is checked here, on the server. The app never saw it before the
    // callback — the gateway minted it — so whatever arrived at the listener is
    // only a candidate until this call accepts it. Nothing sensitive rides in
    // that URL, so a spoofed callback costs one rejected request and nothing
    // else.
    final (ok, error) = await client.finalizeCallback(code: code, state: state);
    if (!ok) {
      return _settle(
        connector,
        error?.message ?? "Couldn't finish the sign-in.",
      );
    }

    this.state = const ConnectorLinkState();
    return null;
  }

  /// Write [token] into the master store and project it into the agent.
  ///
  /// Two writes, in this order, and both are needed: the master is what makes a
  /// connector work for *every* agent, and the projection is what makes it work
  /// for the one running right now.
  Future<String?> adoptToken(ConnectorToken token) async {
    try {
      await ref.read(connectorTokenStoreProvider).save(token);
    } on Object catch (error) {
      return "Couldn't save the connector token: $error";
    }
    return projectTokens();
  }

  /// Re-project every stored token into the selected agent.
  ///
  /// Called after any change to the master store, and cheap enough to call when
  /// in doubt: projecting is idempotent by contract.
  Future<String?> projectTokens() async {
    final tool = ref.read(extensionAgentProvider);
    final project = ref
        .read(agentExtensionsProvider(tool))
        ?.mcp
        ?.projectConnectorTokens;
    // A null projection is not an error: it means this agent has no concept of
    // OAuth connectors. The screen says so; it doesn't fail a save over it.
    if (project == null) return null;

    try {
      final tokens = await ref.read(connectorTokenStoreProvider).read();
      await project(tokens.values.toList());
    } on AgentExtensionException catch (error) {
      return error.message;
    } on Object catch (error) {
      return "Couldn't hand the connector tokens to the agent: $error";
    }
    return null;
  }

  /// Forget a connector locally: drop its token and re-project so the agent
  /// stops offering a tool that no longer works.
  Future<String?> forget(String connector) async {
    try {
      await ref.read(connectorTokenStoreProvider).remove(connector);
    } on Object catch (error) {
      return "Couldn't remove the connector token: $error";
    }
    return projectTokens();
  }

  /// Stop waiting, at the user's request. The provider may still complete in
  /// the browser — that late callback finds no listener, and the backend's poll
  /// picks up the result on its own.
  Future<void> cancel() async {
    await _cancelPending();
    state = const ConnectorLinkState();
  }

  String? _settle(String connector, String message) {
    state = ConnectorLinkState(message: message, failed: connector);
    return null;
  }

  Future<void> _cancelPending() async {
    await _clearListener();
    if (state.pending != null) state = const ConnectorLinkState();
  }

  Future<void> _clearListener() async {
    final listener = _listener;
    _listener = null;
    await listener?.close();
  }
}

final connectorLinkControllerProvider =
    NotifierProvider<ConnectorLinkController, ConnectorLinkState>(
      ConnectorLinkController.new,
    );

/// Every connector's state on this device, refreshed while the screen is open.
///
/// Polls only while something is actually settling. A list where every row has
/// come to rest has nothing to learn from another request, and hammering the
/// gateway for an answer that can't change would be rude to a backend shared
/// with every other Grid on the network.
final deviceConnectorsProvider = StreamProvider<List<DeviceConnector>>((
  ref,
) async* {
  final device = ref.watch(selectedNetworkProvider);
  if (device == null || device.deviceId.isEmpty) {
    yield const [];
    return;
  }
  final client = ref.watch(connectorGatewayClientProvider);

  while (true) {
    final (connectors, _) = await client.deviceConnectors(device.deviceId);
    // A failed poll yields nothing rather than an empty list: blanking every
    // row because one request timed out would be a worse lie than a stale one.
    if (connectors != null) yield connectors;
    if (connectors != null && !connectors.any((c) => c.status.isSettling)) {
      return;
    }
    await Future<void>.delayed(kConnectorPollInterval);
  }
});
