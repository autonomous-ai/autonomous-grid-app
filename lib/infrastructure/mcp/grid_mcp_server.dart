import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../features/agents/logic/grid_chart_skill.dart';
import '../../features/agents/logic/grid_delegate_skill.dart';
import '../../features/agents/logic/grid_host_skill.dart';
import '../../features/agents/logic/grid_loop_skill.dart';
import '../../features/agents/logic/grid_research_skill.dart';
import '../../features/agents/logic/grid_schedule_skill.dart';
import '../../features/agents/logic/grid_serve_skill.dart';
import '../../features/agents/logic/grid_web_skill.dart';
import '../../features/chat/logic/commands/chat_command.dart';
import '../../shared/skills/agent_skill_home.dart';
import 'grid_agent_scripts.dart';
import 'grid_mcp_tools.dart';

/// Grid's own MCP server, running inside the app on loopback.
///
/// **In the app, not a child process**, and that is the point rather than a
/// shortcut. `grid_ask` has to reach the running app — `/loop`, `/goal` and
/// `/schedule` are the app's, and a stdio server spawned by the agent would only
/// have to call back here anyway. It also removes the failure mode a separate
/// binary brings: no process to fail to start, nothing to install, and on Hermes
/// no dependency on a python package that reinstalls quietly wipe.
///
/// **A token per turn, not per app.** The agent is answering *some* chat, and
/// the tool call arrives out of band with no way to say which. So each turn is
/// handed its own bearer token and the token is the chat: `grid_ask` from a turn
/// in chat A can only ever start a loop in chat A, and a token outlives its turn
/// by nothing.
class GridMcpServer {
  GridMcpServer({required this.onAsk, Random? random})
    : _random = random ?? Random.secure();

  /// Runs the command an agent asked for, in the chat its token was minted for.
  /// Returns what to tell the agent — the same sentence the user would see.
  final Future<String> Function(String chatId, ChatCommandCall call) onAsk;

  final Random _random;
  final Map<String, String> _chatByToken = {};
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
  /// Minting **replaces** whatever token this chat already had. A chat has one
  /// turn in flight at a time, so the previous turn's token has nothing left to
  /// do — and hanging the lifetime on the next mint means no sender has to
  /// remember a `revoke` in a `finally` it does not have. [revoke] is still
  /// there for a turn that ends knowing it was the last.
  String mintTurnToken(String chatId) {
    _chatByToken.removeWhere((_, chat) => chat == chatId);
    final token = List.generate(
      32,
      (_) => _alphabet[_random.nextInt(_alphabet.length)],
    ).join();
    _chatByToken[token] = chatId;
    return token;
  }

  void revoke(String token) => _chatByToken.remove(token);

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
      final reply = await _dispatch(
        chatId,
        '${payload['method']}',
        payload['params'],
      );
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
    return _chatByToken[header.substring(prefix.length)];
  }

  Future<Map<String, Object?>> _dispatch(
    String chatId,
    String method,
    Object? params,
  ) async {
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
        return {'result': await _call(chatId, params)};
      default:
        return {
          'error': {'code': -32601, 'message': 'Unknown method: $method'},
        };
    }
  }

  Future<Map<String, Object?>> _call(String chatId, Object? params) async {
    final map = params is Map<String, Object?> ? params : const {};
    final name = '${map['name']}';
    final arguments = map['arguments'];
    return switch (name) {
      'grid_ask' => await _ask(chatId, arguments),
      'grid_guide' => _guide(arguments),
      _ => _text('No tool called "$name".', isError: true),
    };
  }

  Future<Map<String, Object?>> _ask(String chatId, Object? arguments) async {
    final outcome = readGridAsk(arguments);
    return switch (outcome) {
      // A refusal is a *result*, not a transport error: the agent has to read it
      // and say something to the user, and an error object it may never surface
      // would leave them told nothing at all.
      GridAskRefused(:final message) => _text(message, isError: true),
      GridAskAccepted(:final call) => _text(await onAsk(chatId, call)),
    };
  }

  Map<String, Object?> _guide(Object? arguments) {
    final topic = switch (arguments) {
      final Map<String, Object?> map => '${map['topic']}',
      _ => '',
    };
    final body = kGridGuides[topic];
    if (body == null) {
      return _text(
        'No guide called "$topic". Try: ${kGridGuides.keys.join(', ')}.',
        isError: true,
      );
    }
    return _text(body);
  }

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

/// What `grid_guide` can hand back, keyed by the topic in its schema.
///
/// The card bodies, reused verbatim rather than rewritten — they are the same
/// words that were being installed into the user's home, and having them in one
/// place is what stops the tool and the card from drifting while both exist.
Map<String, String> get kGridGuides => {
  'delegate': skillCardBody(kGridDelegateSkillMd),
  'loop': skillCardBody(kGridLoopSkillMd),
  'host': skillCardBody(gridHostSkillMd(uvPath: gridSkillUvPath())),
  'chart': skillCardBody(kGridChartSkillMd),
  'schedule': skillCardBody(kGridScheduleSkillMd),
  // The three that name scripts. Same bodies the cards carried, built against
  // Grid's own folder instead of a skill folder inside the agent's home — see
  // [gridAgentScriptsDir]. A getter rather than a const because those paths are
  // resolved from `~/.grid` at call time, and a test that moves GRID_HOME has to
  // move these with it.
  'web': skillCardBody(
    gridWebSkillMd(
      searchScriptPath: gridAgentScriptPath('search.py'),
      readScriptPath: gridAgentScriptPath('read.py'),
    ),
  ),
  'research': skillCardBody(
    gridResearchSkillMd(
      searchScriptPath: gridAgentScriptPath('search.py'),
      readScriptPath: gridAgentScriptPath('read.py'),
    ),
  ),
  'serve': skillCardBody(
    gridServeSkillMd(
      uvPath: gridSkillUvPath(),
      serveScriptPath: gridAgentScriptPath('serve.py'),
      stateDir: gridServeStateDir().path,
    ),
  ),
};

/// A skill card without its YAML front-matter.
///
/// The front-matter is retrieval metadata for a folder of cards; over MCP the
/// tool's own description does that job, and sending the header too would tell
/// the model to look for a file that is no longer there.
String skillCardBody(String card) {
  final text = card.trimLeft();
  if (!text.startsWith('---')) return text.trim();
  final end = text.indexOf('\n---', 3);
  if (end < 0) return text.trim();
  return text.substring(text.indexOf('\n', end + 1) + 1).trim();
}
