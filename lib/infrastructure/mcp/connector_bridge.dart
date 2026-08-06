import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../../features/agents/logic/connector_runtime.dart';
import '../../features/agents/logic/connector_token.dart';
import '../../features/agents/logic/rest_entry.dart';
import 'mcp_proxy.dart';
import 'rest_invoker.dart';

/// Serves a connector's REST surface to the agents as ordinary MCP tools.
///
/// **Why this exists.** An agent can call MCP tools and nothing else. A provider
/// whose grant no MCP server will accept — Gmail with a send-only scope is the
/// case that forced this — still has a REST API that works perfectly well with
/// the token we hold. Something has to sit between the two, and this is it.
///
/// **Why in the app rather than anywhere else.** The obvious objection is that a
/// server inside a desktop app is only up while the app is up. That is not a
/// limitation here: the app *spawns* the agents, so there is no moment when an
/// agent is running and this is not. A separate daemon or a CLI subcommand would
/// buy availability nobody can use, at the cost of a second process to install,
/// version and debug.
///
/// **What it deliberately does not know.** No provider appears anywhere in this
/// file. Everything specific — the URL, the method, the header convention, the
/// body shape — arrives in [RestEntry], which the gateway issues. Adding Slack
/// is a backend row. If a provider's name ever needs to be typed in here, the
/// design has failed and the fix belongs in the payload instead.
///
/// The agents see a plain streamable-HTTP MCP server on loopback, so the whole
/// arrangement is invisible to the projection layer and costs nothing per agent.
class ConnectorBridge {
  ConnectorBridge({
    required this.readTokens,
    required this.restEntryFor,
    RestInvoker? invoker,
    McpProxy? proxy,
    Directory? home,
  }) : _invoker = invoker ?? RestInvoker(),
       _proxyClient = proxy ?? McpProxy(),
       _home = home;

  /// Read straight from the master store, per call. Never cached.
  ///
  /// The bridge is the one component that can afford to be perfectly fresh, and
  /// it should be: an MCP entry written into a config file is a *snapshot* of a
  /// credential, which is the whole reason the refresh sweep has to re-project
  /// into every agent. Reading here means a token renewed thirty seconds ago is
  /// already in use, and a missed projection cannot strand a live connector.
  final Future<Map<String, ConnectorToken>> Function() readTokens;

  /// Resolves the REST surface for a connector — the gateway's, or the local
  /// stand-in while the gateway has not shipped one.
  final RestEntry? Function(ConnectorToken token) restEntryFor;

  /// Renew a connector's credential, returning null on success and a sentence
  /// on failure — `ConnectorLinkController.refresh`'s contract, passed in.
  ///
  /// **Why the bridge needs this at all.** [readTokens] keeps it perfectly
  /// fresh with respect to the *store*, which is not the same as fresh with
  /// respect to the *provider*. Renewal is a timer in `ConnectorRefreshService`,
  /// and a timer only fires while the app is up and awake. Three windows where
  /// it has not yet run and an agent calls anyway: the minutes right after a
  /// launch that followed a long close (the sweep is a network round trip), a
  /// machine resumed from sleep with the timer behind, and a provider that
  /// revoked early. In all three the store holds a dead token and this served
  /// it verbatim, so the agent got a 401 the app could have prevented — with a
  /// live `refresh_token` sitting one file away.
  ///
  /// Null means "nobody wired renewal up": the call still goes out with what
  /// the store holds, which is exactly the old behaviour.
  /// How a dead credential is renewed, wired by whoever starts the bridge
  /// (`ConnectorRefreshScope`) rather than passed in here.
  ///
  /// Not a constructor argument because the half that knows how to renew — a
  /// self-registered token goes back to its provider, a gateway one to the
  /// gateway, and a renewed token has to be re-projected into every agent —
  /// is the connector link controller, and every agent adapter reads this
  /// bridge for its endpoint. Taking that controller here would close a loop
  /// through the whole agents feature. Null until wired, which the renewal
  /// path already reports as "could not renew" rather than crashing.
  Future<String?> Function(String connector)? refreshToken;

  final RestInvoker _invoker;
  final McpProxy _proxyClient;
  final Directory? _home;

  /// The provider's session id per connector, when it issues one.
  ///
  /// Kept in memory only. It identifies a conversation with the provider, not
  /// the user, and it is worthless after a restart — writing it anywhere would
  /// be persisting something that is stale by definition. GitHub's server issues
  /// one and also answers fine without it; Canva's issues none at all.
  final Map<String, String> _sessions = {};

  /// Renewals in flight, keyed by connector.
  ///
  /// Two agents calling one connector at the same moment both read the same
  /// expired token, and without this both would renew it. That is not merely
  /// wasteful: providers routinely invalidate the old `refresh_token` when they
  /// issue a new one, so the second exchange can revoke the first one's result
  /// and leave the store holding a credential the provider has already retired.
  /// The second caller awaits the first instead.
  final Map<String, Future<void>> _refreshing = {};

  HttpServer? _server;

  /// The port in use, or null before [start].
  int? get port => _server?.port;

  Directory get _directory => _home == null
      ? GridPaths.connectorsDir
      : Directory('${_home.path}/connectors');

  File get _portFile => File('${_directory.path}/bridge.json');

  /// The base URL an agent config should point at for [connector].
  String? endpointFor(String connector) {
    final active = _server;
    if (active == null) return null;
    return 'http://127.0.0.1:${active.port}/c/${Uri.encodeComponent(connector)}/mcp';
  }

  /// Bind loopback and start answering.
  ///
  /// The port is remembered and reused. A port that changed every launch would
  /// rewrite every agent's config file on every start — churn on files that
  /// belong to the user, and a stale entry for anyone whose agent was mid-run.
  Future<void> start() async {
    if (_server != null) return;
    final remembered = await _rememberedPort();
    // Loopback only. There is no reason for anything off this machine to reach
    // a service that holds the user's credentials.
    for (final candidate in [?remembered, 0]) {
      try {
        _server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          candidate,
        );
        break;
      } on SocketException {
        // The remembered port was taken by something else; fall through to an
        // ephemeral one rather than refusing to start.
      }
    }
    final active = _server;
    if (active == null) return;
    await _rememberPort(active.port);
    active.listen(_handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _invoker.close();
    _proxyClient.close();
    // The provider's sessions belong to the connections just dropped; keeping
    // them would send a dead id on the next start.
    _sessions.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    final connector = _connectorOf(request.uri.path);
    if (connector == null) {
      await _send(request, HttpStatus.notFound, {'error': 'unknown path'});
      return;
    }

    // Hermes probes an HTTP MCP URL before connecting and refuses anything that
    // answers with HTML — a guard against a config pointing at a web app's root
    // (`mcp_tool.py:2872`). Answer GET/HEAD as JSON so the probe passes.
    if (request.method == 'GET' || request.method == 'HEAD') {
      await _send(request, HttpStatus.ok, {
        'name': 'grid-connector-bridge',
        'connector': connector,
      });
      return;
    }
    if (request.method != 'POST') {
      await _send(request, HttpStatus.methodNotAllowed, {'error': 'use POST'});
      return;
    }

    Object? payload;
    try {
      payload = jsonDecode(await utf8.decoder.bind(request).join());
    } on Object {
      await _send(request, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      return;
    }
    if (payload is! Map) {
      await _send(request, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'error': {'code': -32600, 'message': 'Invalid request'},
      });
      return;
    }

    final method = payload['method'];
    final id = payload['id'];
    // A notification has no id and takes no reply — `notifications/initialized`
    // arrives right after the handshake, and answering it is a protocol error.
    if (id == null) {
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }

    // A connector whose way in is its own MCP server is forwarded whole, before
    // any of the local handling below: this bridge has nothing to add to a
    // conversation between an agent and a real MCP server, and answering
    // `initialize` on its behalf would describe the wrong server's capabilities.
    final proxied = await _proxy(connector, payload.cast<String, Object?>());
    if (proxied != null) {
      await _send(request, HttpStatus.ok, proxied);
      return;
    }

    final result = await _dispatch(
      connector: connector,
      method: method is String ? method : '',
      params: payload['params'] is Map
          ? (payload['params'] as Map).cast<String, Object?>()
          : const {},
    );
    await _send(request, HttpStatus.ok, {
      'jsonrpc': '2.0',
      'id': id,
      ...result,
    });
  }

  /// Forward to the connector's own MCP server, or null when that is not how
  /// this connector is reached.
  ///
  /// Null means "handle it locally" — a REST-backed connector, or one whose
  /// token has gone. Returning null rather than an error keeps the decision in
  /// one place: [effectiveTransport] answers it, exactly as it does for the
  /// projection and the screen.
  Future<Map<String, Object?>?> _proxy(
    String connector,
    Map<String, Object?> payload,
  ) async {
    var token = (await readTokens())[connector];
    if (token == null) return null;
    if (effectiveTransport(token) != ConnectorTransport.mcp) return null;

    // Renewed first, for the same reason a REST call is: the timer that would
    // otherwise have done it only runs while the app is awake.
    token = await _fresh(connector, token);
    final entry = token.mcpEntry;
    if (entry == null) return null;

    final result = await _proxyClient.forward(
      entry: entry,
      token: token,
      payload: payload,
      sessionId: _sessions[connector],
    );
    // Remembered per connector, not per agent: two agents talking to one
    // provider through this bridge are two clients of the same session, which
    // is what the provider already assumes when it hands the id to a shared
    // address.
    final session = result.sessionId;
    if (session != null) _sessions[connector] = session;
    return result.body;
  }

  Future<Map<String, Object?>> _dispatch({
    required String connector,
    required String method,
    required Map<String, Object?> params,
  }) async {
    switch (method) {
      case 'initialize':
        return {
          'result': {
            // Echo the client's version when it names one. Hermes seeds
            // `2025-03-26`; disagreeing here fails the handshake outright.
            'protocolVersion': params['protocolVersion'] is String
                ? params['protocolVersion']
                : '2025-03-26',
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'grid-connector-bridge', 'version': '1'},
          },
        };
      case 'ping':
        return {'result': <String, Object?>{}};
      case 'tools/list':
        final entry = await _entryFor(connector);
        return {
          'result': {
            'tools': [
              for (final tool in entry?.tools ?? const <RestTool>[])
                {
                  'name': tool.name,
                  'description': tool.description,
                  'inputSchema': tool.inputSchema,
                },
            ],
          },
        };
      case 'tools/call':
        return {'result': await _callTool(connector, params)};
      default:
        return {
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        };
    }
  }

  Future<Map<String, Object?>> _callTool(
    String connector,
    Map<String, Object?> params,
  ) async {
    final tokens = await readTokens();
    var token = tokens[connector];
    if (token == null) {
      // Disconnected while a session was open. Say so plainly — the agent will
      // relay it, and "reconnect it in Grid" is something the user can act on.
      return _toolError(
        'That connector is no longer connected in Grid. Reconnect it and try '
        'again.',
      );
    }
    token = await _fresh(connector, token);
    final entry = restEntryFor(token);
    final name = params['name'];
    final tool = entry?.tools.where((t) => t.name == name).firstOrNull;
    if (entry == null || tool == null) {
      return _toolError('This connector has no tool called "$name".');
    }

    final arguments = params['arguments'] is Map
        ? (params['arguments'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final result = await _invoker.call(
      entry: entry,
      tool: tool,
      token: token,
      arguments: arguments,
    );
    return {
      'content': [
        {'type': 'text', 'text': result.text},
      ],
      'isError': !result.ok,
    };
  }

  /// [token], renewed first if it is close enough to expiry to be worth it.
  ///
  /// Returns the token to actually call with. **Never throws and never fails
  /// the call**: a renewal that could not happen — no [refreshToken] wired, the
  /// network down, the provider refusing — falls through to the stored token
  /// and lets the request go out. It may well still work, since [ConnectorToken
  /// .isExpired] carries a five-minute head start, and a provider's own verdict
  /// beats a guess made here. Turning "couldn't renew" into a refused tool call
  /// would invent failures the old code did not have.
  ///
  /// The re-read afterwards is the point of the exercise: `refresh` writes
  /// through the store, so the new credential is only visible by asking again.
  Future<ConnectorToken> _fresh(String connector, ConnectorToken token) async {
    final renew = refreshToken;
    if (renew == null || !token.needsRefresh()) return token;

    // Join the renewal already running for this connector rather than starting
    // a second one. The entry is cleared in the body's own `finally`, so a
    // later call renews again rather than reusing a settled result.
    //
    // Deliberately an immediately-invoked async body and not
    // `Future(...).whenComplete(...)`: the latter deadlocked here. Measured, not
    // reasoned about — the renewal callback ran to completion and the awaited
    // future never resolved, so the agent's request hung until it timed out.
    final pending = _refreshing[connector];
    if (pending != null) {
      await pending;
    } else {
      final attempt = () async {
        try {
          await renew(connector);
        } on Object {
          // Reported by the controller, which owns the user-facing surface. The
          // bridge's job here is only to have tried.
        } finally {
          _refreshing.remove(connector);
        }
      }();
      _refreshing[connector] = attempt;
      await attempt;
    }

    return (await readTokens())[connector] ?? token;
  }

  /// A failed call is an MCP *result* with `isError`, not a JSON-RPC error.
  ///
  /// The distinction matters: a JSON-RPC error is a protocol fault and clients
  /// may drop the session over it, while `isError` hands the sentence to the
  /// model, which can tell the user or try something else.
  Map<String, Object?> _toolError(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isError': true,
  };

  Future<RestEntry?> _entryFor(String connector) async {
    final token = (await readTokens())[connector];
    return token == null ? null : restEntryFor(token);
  }

  /// `/c/<connector>/mcp` — nothing else is served.
  String? _connectorOf(String path) {
    final parts = path.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length != 3 || parts.first != 'c' || parts.last != 'mcp') {
      return null;
    }
    return Uri.decodeComponent(parts[1]);
  }

  Future<int?> _rememberedPort() async {
    try {
      if (!await _portFile.exists()) return null;
      final decoded = jsonDecode(await _portFile.readAsString());
      final port = decoded is Map ? decoded['port'] : null;
      return port is int && port > 0 && port < 65536 ? port : null;
    } on Object {
      return null;
    }
  }

  Future<void> _rememberPort(int port) async {
    try {
      await _directory.create(recursive: true);
      await _portFile.writeAsString(jsonEncode({'port': port}), flush: true);
    } on Object {
      // Losing the file costs a new port next launch and one config rewrite,
      // which the projection handles. Not worth failing the start over.
    }
  }

  Future<void> _send(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    if (request.method != 'HEAD') {
      request.response.write(jsonEncode(body));
    }
    await request.response.close();
  }
}
