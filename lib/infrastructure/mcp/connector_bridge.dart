import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../../features/agents/logic/connector_token.dart';
import '../../features/agents/logic/rest_entry.dart';
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
    Directory? home,
  }) : _invoker = invoker ?? RestInvoker(),
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

  final RestInvoker _invoker;
  final Directory? _home;

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
    final token = tokens[connector];
    if (token == null) {
      // Disconnected while a session was open. Say so plainly — the agent will
      // relay it, and "reconnect it in Grid" is something the user can act on.
      return _toolError(
        'That connector is no longer connected in Grid. Reconnect it and try '
        'again.',
      );
    }
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
