import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';
import 'package:grid_app/infrastructure/mcp/mcp_proxy.dart';

/// The proxy that lets an MCP connector reach every agent without its
/// credential leaving the app.
///
/// Driven against a real loopback server rather than a mocked client: the two
/// things worth pinning here — what goes out on the wire, and what is understood
/// coming back — are both observable only at that boundary.
void main() {
  late HttpServer server;
  late List<HttpHeaders> seen;
  late List<String> bodies;

  /// What the next request will be answered with.
  late int status;
  late String reply;
  late ContentType replyType;
  late String? issueSession;

  setUp(() async {
    seen = [];
    bodies = [];
    status = 200;
    reply = '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}';
    replyType = ContentType.json;
    issueSession = null;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seen.add(request.headers);
      bodies.add(await utf8.decoder.bind(request).join());
      request.response
        ..statusCode = status
        ..headers.contentType = replyType;
      if (issueSession != null) {
        request.response.headers.set('Mcp-Session-Id', issueSession!);
      }
      request.response.write(reply);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  McpEntry entry() => McpEntry(
    url: 'http://127.0.0.1:${server.port}/mcp',
    headers: const {'Authorization': 'Bearer secret-token'},
  );

  const token = ConnectorToken(connector: 'demo', accessToken: 'secret-token');

  const payload = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'};

  test('both content types are always offered', () async {
    final proxy = McpProxy();
    addTearDown(proxy.close);

    await proxy.forward(entry: entry(), token: token, payload: payload);

    // Not a preference. Canva answers 406 to a request naming only
    // application/json, and says so in the body.
    expect(
      seen.single.value(HttpHeaders.acceptHeader),
      'application/json, text/event-stream',
    );
  });

  test('the credential rides on the request, not in any config', () async {
    final proxy = McpProxy();
    addTearDown(proxy.close);

    await proxy.forward(entry: entry(), token: token, payload: payload);

    expect(seen.single.value('Authorization'), 'Bearer secret-token');
    // And the body is forwarded untouched — this is a forwarder, not a second
    // MCP implementation.
    expect(jsonDecode(bodies.single), payload);
  });

  test('a JSON reply is returned as-is', () async {
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    expect(result.body['result'], {'ok': true});
    expect(result.sessionId, isNull);
  });

  test('an SSE reply is unwrapped to its JSON-RPC object', () async {
    replyType = ContentType('text', 'event-stream');
    reply =
        'event: message\n'
        'data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    expect(result.body['result'], {'ok': true});
  });

  test('the last SSE event wins, not the first', () async {
    replyType = ContentType('text', 'event-stream');
    // A server may narrate progress before answering. The reply to the request
    // is the one that arrives last.
    reply =
        'event: message\n'
        'data: {"jsonrpc":"2.0","method":"notifications/progress"}\n'
        '\n'
        'event: message\n'
        'data: {"jsonrpc":"2.0","id":1,"result":{"final":true}}\n\n';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    expect(result.body['result'], {'final': true});
  });

  test('a data payload split across lines is rejoined', () async {
    replyType = ContentType('text', 'event-stream');
    // SSE allows one event's data to span several `data:` lines, and a large
    // tools/list is exactly where that turns up.
    reply =
        'event: message\n'
        'data: {"jsonrpc":"2.0","id":1,\n'
        'data: "result":{"big":true}}\n\n';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    expect(result.body['result'], {'big': true});
  });

  test('an SSE body mislabelled as JSON is still read', () async {
    // The mime type decides first, but a body opening with `event:`/`data:`
    // is SSE whatever the header claimed.
    replyType = ContentType.json;
    reply = 'data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    expect(result.body['result'], {'ok': true});
  });

  test('a session id is returned so the caller can echo it back', () async {
    issueSession = 'sess-123';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final first = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );
    expect(first.sessionId, 'sess-123');

    await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
      sessionId: first.sessionId,
    );
    expect(seen.last.value('Mcp-Session-Id'), 'sess-123');
  });

  test('a refused request becomes a JSON-RPC error carrying the id', () async {
    status = 401;
    reply = '{"error":"invalid_token","error_description":"expired"}';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    final error = result.body['error']! as Map;
    expect(result.body['id'], 1, reason: 'the agent matches replies by id');
    expect(error['code'], -32603);
    expect(error['message'], contains('needs signing in again'));
  });

  test('an unreachable server never echoes the URL back', () async {
    final proxy = McpProxy();
    addTearDown(proxy.close);
    // Captured while the port is still readable, then closed so connecting
    // fails — `server.port` throws once it is unbound.
    final dead = entry();
    await server.close(force: true);

    final result = await proxy.forward(
      entry: dead,
      token: token,
      payload: payload,
    );

    final message = (result.body['error']! as Map)['message']! as String;
    // An HttpException's toString carries the full URI, and this path runs with
    // a credential in the headers.
    expect(message, isNot(contains('127.0.0.1')));
    expect(message, contains("Couldn't reach the connector"));
  });

  test('an unreadable body degrades to an error, never a throw', () async {
    reply = 'not json at all';
    final proxy = McpProxy();
    addTearDown(proxy.close);

    final result = await proxy.forward(
      entry: entry(),
      token: token,
      payload: payload,
    );

    expect(
      (result.body['error']! as Map)['message'],
      contains('could not read'),
    );
  });
}
