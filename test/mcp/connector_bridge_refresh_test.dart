import 'dart:convert';
import 'dart:io';

import 'package:grid_app/features/agents/logic/connector_token.dart';
import 'package:grid_app/features/agents/logic/rest_entry.dart';
import 'package:grid_app/infrastructure/mcp/connector_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bridge keeps agent transport stable and renews credentials before use.
///
/// Driven over a real socket rather than by calling private methods: the bridge
/// is deliberately free of Flutter so it can be exercised the way an agent
/// exercises it, and the question these tests answer — *which* token reached the
/// provider — is only observable from the other end of the wire.
void main() {
  late HttpServer provider;
  late List<String> seenAuth;
  late Directory home;

  setUp(() async {
    seenAuth = [];
    // A home of its own per test. Without one the bridge resolves `GridPaths`
    // and rewrites the developer's real `~/.grid/connectors/bridge.json` —
    // which it did, on the first run of this file, pointing the machine's
    // agents at a port owned by a test process that had already exited.
    home = await Directory.systemTemp.createTemp('bridge-refresh-test');
    addTearDown(() => home.delete(recursive: true));
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      seenAuth.add(request.headers.value('Authorization') ?? '');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      await request.response.close();
    });
  });

  tearDown(() => provider.close(force: true));

  RestEntry entryFor(HttpServer server) => RestEntry(
    auth: const RestAuth(),
    tools: [
      RestTool(
        name: 'ping',
        description: 'ping',
        params: const {},
        request: RestRequest(
          method: 'GET',
          url: 'http://127.0.0.1:${server.port}/ping',
        ),
      ),
    ],
  );

  ConnectorToken tokenWith({
    required String access,
    required Duration expiresIn,
    String? refresh = 'r1',
  }) => ConnectorToken(
    connector: 'demo',
    accessToken: access,
    refreshToken: refresh,
    expiresAt: DateTime.now().add(expiresIn),
    canRefresh: refresh != null,
  );

  /// Start a bridge, call `ping` through it [times] times, and stop.
  Future<void> callTool(
    ConnectorBridge bridge, {
    int times = 1,
    bool concurrently = false,
  }) async {
    await bridge.start();
    addTearDown(bridge.stop);
    final url = Uri.parse(bridge.endpointFor('demo')!);
    final client = HttpClient();
    addTearDown(client.close);

    Future<void> once() async {
      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': 'ping', 'arguments': <String, Object?>{}},
        }),
      );
      final response = await request.close();
      await response.drain<void>();
    }

    if (concurrently) {
      await Future.wait([for (var i = 0; i < times; i++) once()]);
    } else {
      for (var i = 0; i < times; i++) {
        await once();
      }
    }
  }

  Future<Map<String, Object?>> sendRaw(
    ConnectorBridge bridge, {
    required String path,
    required String body,
    String method = 'POST',
  }) async {
    await bridge.start();
    addTearDown(bridge.stop);
    final client = HttpClient();
    addTearDown(client.close);
    final uri = Uri.parse('http://127.0.0.1:${bridge.port}$path');
    final request = await client.openUrl(method, uri);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return {
      'status': response.statusCode,
      if (text.isNotEmpty) ...jsonDecode(text) as Map<String, Object?>,
    };
  }

  test('local protocol failures stay inside JSON-RPC over HTTP 200, so agents '
      'do not retry them as transport failures', () async {
    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => const {},
      restEntryFor: (_) => null,
    );

    final unknownPath = await sendRaw(bridge, path: '/wrong', body: '{}');
    final malformed = await sendRaw(bridge, path: '/c/demo/mcp', body: '{');

    expect(unknownPath['status'], HttpStatus.ok);
    expect((unknownPath['error']! as Map)['code'], -32600);
    expect(malformed['status'], HttpStatus.ok);
    expect((malformed['error']! as Map)['code'], -32700);
  });

  test(
    'an internal bridge failure is JSON-RPC over HTTP 200, so a long-running '
    'agent turn stays alive',
    () async {
      final bridge = ConnectorBridge(
        home: home,
        readTokens: () async => throw StateError('boom'),
        restEntryFor: (_) => null,
      );

      final reply = await sendRaw(
        bridge,
        path: '/c/demo/mcp',
        body: jsonEncode({'jsonrpc': '2.0', 'id': 7, 'method': 'tools/list'}),
      );

      expect(reply['status'], HttpStatus.ok);
      expect(reply['id'], 7);
      expect((reply['error']! as Map)['code'], -32603);
    },
  );

  test('an expiring token is renewed before the provider is called', () async {
    var stored = tokenWith(
      access: 'old',
      expiresIn: const Duration(minutes: 1),
    );
    var refreshCalls = 0;

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
    );
    bridge.refreshToken = (_) async {
      refreshCalls++;
      // What the real controller does: write through the store, so the
      // re-read that follows is the only way to see the new credential.
      stored = tokenWith(access: 'new', expiresIn: const Duration(hours: 1));
      return null;
    };

    await callTool(bridge);

    expect(refreshCalls, 1);
    // The whole point: the *renewed* token went out, not the one the call
    // started with.
    expect(seenAuth.single, 'Bearer new');
  });

  test('a healthy token is used as-is, with no renewal', () async {
    final stored = tokenWith(
      access: 'fresh',
      expiresIn: const Duration(hours: 2),
    );
    var refreshCalls = 0;

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
    );
    bridge.refreshToken = (_) async {
      refreshCalls++;
      return null;
    };

    await callTool(bridge);

    expect(refreshCalls, 0, reason: 'nothing was close enough to expiry');
    expect(seenAuth.single, 'Bearer fresh');
  });

  test('a token nothing can renew is not sent to the refresher', () async {
    // No refresh_token, so `canBeRefreshed` is false: renewing would spend a
    // request to be told what the store already knows.
    final stored = tokenWith(
      access: 'stale',
      expiresIn: const Duration(minutes: 1),
      refresh: null,
    );
    var refreshCalls = 0;

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
    );
    bridge.refreshToken = (_) async {
      refreshCalls++;
      return null;
    };

    await callTool(bridge);

    expect(refreshCalls, 0);
    expect(seenAuth.single, 'Bearer stale');
  });

  test('a failed renewal still lets the call go out', () async {
    final stored = tokenWith(
      access: 'old',
      expiresIn: const Duration(minutes: 1),
    );

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
      // Both shapes a renewal can fail in: the controller's "returned a
      // sentence", and an outright throw.
    );

    bridge.refreshToken = (_) async => throw const SocketException('offline');

    await callTool(bridge);

    // The five-minute head start means this may well still be valid, and the
    // provider's verdict beats a guess made here.
    expect(seenAuth.single, 'Bearer old');
  });

  test('two concurrent calls renew once, not twice', () async {
    var stored = tokenWith(
      access: 'old',
      expiresIn: const Duration(minutes: 1),
    );
    var refreshCalls = 0;

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
    );
    bridge.refreshToken = (_) async {
      refreshCalls++;
      // A real exchange is a network round trip; both callers have to be
      // in flight across it for the race to be the one being tested.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      stored = tokenWith(access: 'new', expiresIn: const Duration(hours: 1));
      return null;
    };

    await callTool(bridge, times: 2, concurrently: true);

    // Two exchanges would be worse than wasteful: providers routinely retire
    // the old refresh_token when they issue a new one, so the second can revoke
    // the first one's result.
    expect(refreshCalls, 1);
    expect(seenAuth, ['Bearer new', 'Bearer new']);
  });

  test('a later call renews again once the first has settled', () async {
    var stored = tokenWith(
      access: 'old',
      expiresIn: const Duration(minutes: 1),
    );
    var refreshCalls = 0;

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
    );
    bridge.refreshToken = (_) async {
      refreshCalls++;
      // Still expiring afterwards, so the guard is the only thing that could
      // suppress the second attempt — and it must not, once settled.
      stored = tokenWith(
        access: 'renewed$refreshCalls',
        expiresIn: const Duration(minutes: 1),
      );
      return null;
    };

    await callTool(bridge, times: 2);

    expect(
      refreshCalls,
      2,
      reason: 'the in-flight map is cleared on completion',
    );
    expect(seenAuth, ['Bearer renewed1', 'Bearer renewed2']);
  });

  test('with no refresher wired, the stored token is used unchanged', () async {
    final stored = tokenWith(
      access: 'old',
      expiresIn: const Duration(minutes: 1),
    );

    final bridge = ConnectorBridge(
      home: home,
      readTokens: () async => {'demo': stored},
      restEntryFor: (_) => entryFor(provider),
    );

    await callTool(bridge);

    expect(seenAuth.single, 'Bearer old');
  });
}
