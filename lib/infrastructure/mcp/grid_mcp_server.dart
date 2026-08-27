import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api/relay_web_client.dart';
import 'grid_mcp_tools.dart';

/// Grid's own MCP server, running inside the app on loopback.
///
/// **In the app, not a child process**, and that is the point rather than a
/// shortcut: the grid's credential stays in the app, the agent is handed a
/// token that speaks only for its chat, and there is no process to fail to
/// start, nothing to install, and on Hermes no dependency on a python package
/// that reinstalls quietly wipe.
///
/// **Two tools, both the web** — `web_search` and `web_fetch` — see
/// [kGridMcpTools] for why the rest were switched off.
///
/// **A token per run, not per app.** The agent is answering *some* chat, and the
/// tool call arrives out of band with no way to say which. So each run is handed
/// its own bearer token and the token is the chat — which is what lets a token
/// be retired with the turn that held it, rather than living as long as the app.
///
/// A *run* is a turn ([mintTurnToken]) or a whole terminal session
/// ([mintSessionToken]), and the two have to be told apart — a chat can have both
/// at once, and the shorter one must not end the longer one.
class GridMcpServer {
  GridMcpServer({required this.web, required this.relay, Random? random})
    : _random = random ?? Random.secure();

  /// The live web, through the grid.
  final RelayWebClient web;

  /// The grid to go through, read at call time — a chat can outlive the grid
  /// it started on, and null is the honest answer when there is none.
  final ({String baseUrl, String token})? Function() relay;

  final Random _random;
  final Map<String, _Grant> _chatByToken = {};
  HttpServer? _server;

  /// Where the agents should point, or null before [start].
  String? get url {
    final server = _server;
    if (server == null) return null;
    return 'http://127.0.0.1:${server.port}/mcp';
  }

  /// Binds loopback on a port the OS picks.
  ///
  /// Loopback only: this server runs commands in the user's chats, and a
  /// listener on 0.0.0.0 would offer that to the coffee shop.
  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(server.forEach(_handle));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _chatByToken.clear();
  }

  /// A bearer token that speaks for [chatId] until the chat's next turn.
  ///
  /// Minting **replaces whatever turn token this chat already had**. A chat has
  /// one turn in flight at a time, so the previous turn's token has nothing left
  /// to do — and hanging the lifetime on the next mint means no sender has to
  /// remember a `revoke` in a `finally` it does not have. [revoke] is still
  /// there for a turn that ends knowing it was the last.
  ///
  /// It leaves [mintSessionToken]'s grants alone. It used to take every token
  /// the chat had, which killed the tools of any long-lived CLI the same chat
  /// was driving — see there.
  String mintTurnToken(String chatId) =>
      _mint(chatId, session: false, replacing: (grant) => !grant.session);

  /// A bearer token for a **long-lived** agent process in [chatId] — a terminal
  /// session, which connects to this server once at startup and holds that
  /// connection for as long as the CLI is running.
  ///
  /// **A turn token is the wrong lifetime for one**, and using one shipped this
  /// bug: `mintTurnToken` revoked every earlier token for the chat, so the next
  /// turn the *app* sent into that chat — a carry-on, a scheduled task —
  /// pulled the rug from under the running CLI. Its next tool
  /// call came back `HTTP 401`, the transport gave up with `worker quit with
  /// fatal: Transport channel closed`, and every Grid tool stayed dead for the
  /// rest of the session because nothing reconnects.
  ///
  /// The caller owns this one: it lives until [revoke], or until the server
  /// stops. A chat gets one, so opening a second session for the same chat ends
  /// the first's grant.
  String mintSessionToken(String chatId) =>
      _mint(chatId, session: true, replacing: (grant) => grant.session);

  void revoke(String token) => _chatByToken.remove(token);

  /// Issues a token for [chatId], dropping the grants of the same kind it
  /// replaces ([replacing]) and leaving the other kind untouched.
  String _mint(
    String chatId, {
    required bool session,
    required bool Function(_Grant grant) replacing,
  }) {
    _chatByToken.removeWhere(
      (_, grant) => grant.chat == chatId && replacing(grant),
    );
    final token = List.generate(
      32,
      (_) => _alphabet[_random.nextInt(_alphabet.length)],
    ).join();
    _chatByToken[token] = _Grant(chat: chatId, session: session);
    return token;
  }

  static const String _alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    Object? id;
    try {
      if (request.method != 'POST') {
        _writeError(response, id, -32600, 'Use POST for MCP requests.');
        return;
      }
      final chatId = _chatFor(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      if (chatId == null) {
        _writeError(
          response,
          id,
          -32001,
          'This Grid turn is no longer active.',
        );
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        _writeError(response, id, -32700, 'Parse error');
        return;
      }
      if (decoded is! Map) {
        _writeError(response, id, -32600, 'Invalid request');
        return;
      }
      final payload = decoded.cast<String, Object?>();
      id = payload['id'];
      // A notification carries no id and takes no reply — `initialized` is the
      // one that matters, and answering it is a protocol error.
      if (id == null) {
        response.statusCode = HttpStatus.accepted;
        return;
      }
      final reply = await _dispatch('${payload['method']}', payload['params']);
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, ...reply}));
    } on Object catch (error) {
      _writeError(
        response,
        id,
        -32603,
        'Grid could not complete the call: $error',
      );
    } finally {
      await response.close();
    }
  }

  /// Fail inside JSON-RPC, never at the HTTP transport layer.
  ///
  /// Codex and Claude Code may retry or end a long-running turn on HTTP 4xx/5xx.
  /// A JSON-RPC error reaches the model instead, so it can report the failure
  /// without replaying a command that may already have taken effect.
  void _writeError(
    HttpResponse response,
    Object? id,
    int code,
    String message,
  ) {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      }),
    );
  }

  String? _chatFor(String? header) {
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) return null;
    return _chatByToken[header.substring(prefix.length)]?.chat;
  }

  Future<Map<String, Object?>> _dispatch(String method, Object? params) async {
    switch (method) {
      case 'initialize':
        return {
          'result': {
            'protocolVersion': kMcpProtocolVersion,
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'grid', 'version': '1'},
          },
        };
      case 'tools/list':
        return {
          'result': {
            'tools': [for (final tool in kGridMcpTools) tool.toJson()],
          },
        };
      case 'tools/call':
        return {'result': await _call(params)};
      default:
        return {
          'error': {'code': -32601, 'message': 'Unknown method: $method'},
        };
    }
  }

  Future<Map<String, Object?>> _call(Object? params) async {
    final map = params is Map<String, Object?> ? params : const {};
    final name = '${map['name']}';
    final arguments = map['arguments'];
    return switch (name) {
      'web_search' => await _search(arguments),
      'web_fetch' => await _fetch(arguments),
      _ => _text('No tool called "$name".', isError: true),
    };
  }

  /// A refusal is a *result*, not a transport error: the agent has to read it
  /// and say something to the user, and an error object it may never surface
  /// would leave them told nothing at all.
  Future<Map<String, Object?>> _search(Object? arguments) async {
    final args = readWebSearchArgs(arguments);
    if (args == null) {
      return _text('Nothing to search for. Pass `query`.', isError: true);
    }
    final grid = relay();
    if (grid == null) return _text(kWebNeedsGrid, isError: true);
    try {
      final hits = await web.search(
        baseUrl: grid.baseUrl,
        apiKey: grid.token,
        query: args.query,
        maxResults: args.maxResults,
      );
      return _text(formatWebSearchHits(hits));
    } on RelayWebRefused catch (refused) {
      return _text(_refusal(refused), isError: true);
    }
  }

  Future<Map<String, Object?>> _fetch(Object? arguments) async {
    final args = readWebFetchArgs(arguments);
    if (args == null) {
      return _text('Nothing to read. Pass `url`.', isError: true);
    }
    final grid = relay();
    if (grid == null) return _text(kWebNeedsGrid, isError: true);
    try {
      final page = await web.read(
        baseUrl: grid.baseUrl,
        apiKey: grid.token,
        url: args.url,
      );
      return _text(formatWebPage(page, maxChars: args.maxChars));
    } on RelayWebRefused catch (refused) {
      return _text(_refusal(refused), isError: true);
    }
  }

  /// The sentence, plus the one thing the agent acts on without reading it:
  /// whether the same call is worth trying again this turn.
  String _refusal(RelayWebRefused refused) => refused.retryable
      ? refused.message
      : '${refused.message} Not worth retrying in this turn.';

  Map<String, Object?> _text(String text, {bool isError = false}) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    if (isError) 'isError': true,
  };
}

/// The revision of MCP this speaks. Stated rather than echoed back from the
/// client: a server that agrees to whatever it is told supports nothing in
/// particular.
const String kMcpProtocolVersion = '2025-06-18';

/// What the web tools say when the app is on no grid: the same sentence the
/// scripts print, so the user hears one story.
const String kWebNeedsGrid =
    'Web access needs a grid. Open Grid, pick or create a grid, then try '
    'again.';

/// What one bearer token is allowed to speak for: the chat, and whether it
/// belongs to a whole agent **session** or to a single turn.
///
/// The kind is what keeps the two lifetimes from cancelling each other — see
/// [GridMcpServer.mintSessionToken] for the failure that made it necessary.
class _Grant {
  const _Grant({required this.chat, required this.session});

  final String chat;
  final bool session;
}
