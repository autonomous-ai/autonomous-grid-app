import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/relay_web_client.dart';
import 'package:grid_app/infrastructure/mcp/grid_agent_scripts.dart';
import 'package:grid_app/infrastructure/mcp/grid_browser_automation.dart';
import 'package:grid_app/infrastructure/mcp/grid_mcp_server.dart';
import 'package:grid_app/infrastructure/mcp/grid_mcp_tools.dart';

/// The relay, scripted: every call is recorded, and the answer is whatever the
/// test put in — a list of hits, a page, or a refusal to throw.
class FakeRelayWebClient implements RelayWebClient {
  final calls = <({String baseUrl, String apiKey, String what})>[];
  List<WebSearchHit> hits = const [];
  WebPage page = (title: '', text: '');
  RelayWebRefused? refuse;
  Object? crash;

  @override
  Future<List<WebSearchHit>> search({
    required String baseUrl,
    required String apiKey,
    required String query,
    required int maxResults,
  }) async {
    calls.add((baseUrl: baseUrl, apiKey: apiKey, what: '$query/$maxResults'));
    if (crash case final error?) throw error;
    if (refuse case final refused?) throw refused;
    return hits;
  }

  @override
  Future<WebPage> read({
    required String baseUrl,
    required String apiKey,
    required String url,
  }) async {
    calls.add((baseUrl: baseUrl, apiKey: apiKey, what: url));
    if (crash case final error?) throw error;
    if (refuse case final refused?) throw refused;
    return page;
  }
}

const _grid = (baseUrl: 'https://relay.test/v1', token: 'tok');

void main() {
  group('the web tools\' arguments — read strictly, defaulted kindly', () {
    test('a search needs a query and clamps how many hits it asks for, so a '
        'model asking for 500 costs the grid ten', () {
      expect(readWebSearchArgs({'query': ' 0x alpha ', 'max_results': 500}), (
        query: '0x alpha',
        maxResults: kWebSearchMaxResults,
      ));
      expect(
        readWebSearchArgs({'query': 'x'})!.maxResults,
        kWebSearchDefaultResults,
      );
      expect(
        readWebSearchArgs({'query': 'x', 'max_results': 0})!.maxResults,
        1,
      );
      expect(readWebSearchArgs({'query': '  '}), isNull);
      expect(readWebSearchArgs(const {}), isNull);
      expect(readWebSearchArgs('0x alpha'), isNull);
    });

    test('a fetch needs a URL and never returns less than a headline\'s worth '
        'of page', () {
      expect(readWebFetchArgs({'url': 'https://a.test', 'max_chars': 10}), (
        url: 'https://a.test',
        maxChars: kWebFetchMinChars,
      ));
      expect(
        readWebFetchArgs({'url': 'https://a.test'})!.maxChars,
        kWebFetchDefaultChars,
      );
      expect(readWebFetchArgs({'max_chars': 10}), isNull);
    });

    test('hits read as title, URL, excerpt — one block each — and none reads '
        'as the words "No results." rather than an empty string the model '
        'might take for a broken tool', () {
      expect(formatWebSearchHits(const []), 'No results.');
      expect(
        formatWebSearchHits(const [
          (title: 'A', url: 'https://a', excerpt: 'aa'),
          (title: 'B', url: 'https://b', excerpt: 'bb'),
        ]),
        'A\nhttps://a\naa\n\nB\nhttps://b\nbb',
      );
    });

    test('a page is cut at max_chars and says so, and a blank page says it is '
        'blank rather than saying nothing', () {
      expect(
        formatWebPage((title: 'T', text: 'abcdef'), maxChars: 3),
        'T\n\nabc\n…(truncated)',
      );
      expect(
        formatWebPage((title: '', text: ''), maxChars: 3),
        'No readable text found on the page.',
      );
    });
  });

  group('GridMcpServer', () {
    late GridMcpServer server;
    late FakeRelayWebClient web;
    ({String baseUrl, String token})? grid;
    // Null is the user not having picked Grid's Browser tab, which is the
    // default — the browser tests below hand one over deliberately.
    GridBrowserAutomation? browser;

    setUp(() async {
      web = FakeRelayWebClient();
      grid = _grid;
      browser = null;
      server = GridMcpServer(
        web: web,
        relay: () => grid,
        browser: () => browser,
      );
      await server.start();
    });
    tearDown(() => server.stop());

    Future<Map<String, Object?>> sendRaw({
      required String token,
      required String body,
      String method = 'POST',
    }) async {
      final client = HttpClient();
      final request = await client.openUrl(method, Uri.parse(server.url!));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      client.close();
      return {
        'status': response.statusCode,
        if (text.isNotEmpty) ...jsonDecode(text) as Map<String, Object?>,
      };
    }

    Future<Map<String, Object?>> send(
      String token,
      Map<String, Object?> body,
    ) => sendRaw(token: token, body: jsonEncode(body));

    test('listens on loopback only — this runs commands in the user\'s chats, '
        'and a listener on every interface would offer that to the room', () {
      expect(server.url, startsWith('http://127.0.0.1:'));
    });

    test('advertises its tools, so the agent can reach for them', () async {
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      });

      final tools = ((reply['result']! as Map)['tools']! as List)
          .map((t) => (t as Map)['name'])
          .toList();
      expect(tools, ['web_search', 'web_fetch']);
    });

    test('the browser tools are not advertised while the user has not picked '
        'that browser — a tool the agent will be refused at costs it the turn '
        'to find out', () async {
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 10,
        'method': 'tools/list',
      });

      final tools = ((reply['result']! as Map)['tools']! as List)
          .map((t) => (t as Map)['name'])
          .toList();
      expect(tools.where((n) => '$n'.startsWith('browser_')), isEmpty);
    });

    test(
      'once the user picks the Browser tab, its tools join the list',
      () async {
        browser = _FakeBrowser();
        final token = server.mintTurnToken('chat-1');

        final reply = await send(token, {
          'jsonrpc': '2.0',
          'id': 11,
          'method': 'tools/list',
        });

        final tools = ((reply['result']! as Map)['tools']! as List)
            .map((t) => (t as Map)['name'])
            .toList();
        expect(tools, contains('browser_snapshot'));
        expect(tools, contains('browser_click'));
      },
    );

    test('a browser call with the tab turned off is refused as a result the '
        'agent reads, and names the screen that turns it on — an agent can '
        'carry a tool list from an earlier session, or simply guess', () async {
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 12,
        'method': 'tools/call',
        'params': {
          'name': 'browser_snapshot',
          'arguments': <String, Object?>{},
        },
      });

      final result = reply['result']! as Map;
      expect(result['isError'], isTrue);
      expect(
        ((result['content']! as List).first as Map)['text'],
        contains('Settings ▸ Browser'),
      );
    });

    test('a click with no ref is refused before it reaches the page, saying '
        'which snapshot to take it from', () async {
      browser = _FakeBrowser();
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 13,
        'method': 'tools/call',
        'params': {'name': 'browser_click', 'arguments': <String, Object?>{}},
      });

      final result = reply['result']! as Map;
      expect(result['isError'], isTrue);
      expect(
        ((result['content']! as List).first as Map)['text'],
        contains('browser_snapshot'),
      );
    });

    test('a screenshot comes back as a picture with a sentence in front of it, '
        'so the model knows what it is looking at', () async {
      browser = _FakeBrowser();
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 14,
        'method': 'tools/call',
        'params': {
          'name': 'browser_screenshot',
          'arguments': <String, Object?>{},
        },
      });

      final content = (reply['result']! as Map)['content']! as List;
      expect((content.first as Map)['type'], 'text');
      expect((content.last as Map)['type'], 'image');
      expect((content.last as Map)['mimeType'], 'image/png');
    });

    test('a search goes to the grid the app is on, with its credential, and '
        'comes back in the shape the scripts printed', () async {
      final token = server.mintTurnToken('chat-1');
      web.hits = const [(title: 'A', url: 'https://a', excerpt: 'aa')];

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'web_search',
          'arguments': {'query': '0x alpha', 'max_results': 3},
        },
      });

      expect(web.calls.single, (
        baseUrl: _grid.baseUrl,
        apiKey: _grid.token,
        what: '0x alpha/3',
      ));
      final result = reply['result']! as Map<String, Object?>;
      expect(result['isError'], isNull);
      expect(_text(reply), 'A\nhttps://a\naa');
    });

    test('a fetch reads one page and cuts it where it was asked to', () async {
      final token = server.mintTurnToken('chat-1');
      web.page = (title: 'T', text: 'x' * 2000);

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'web_fetch',
          'arguments': {'url': 'https://a.test/p', 'max_chars': 600},
        },
      });

      expect(web.calls.single.what, 'https://a.test/p');
      expect(_text(reply), 'T\n\n${'x' * 600}\n…(truncated)');
    });

    test(
      'a revoked token runs nothing — a token outlives its turn by nothing',
      () async {
        final token = server.mintTurnToken('chat-1');
        server.revoke(token);

        final reply = await send(token, {
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/list',
        });

        expect(reply['status'], HttpStatus.ok);
        expect((reply['error']! as Map)['code'], -32001);
        expect(web.calls, isEmpty);
      },
    );

    test('an unknown token is refused, so nothing else on this machine can '
        'search on somebody\'s grid by guessing the port', () async {
      final reply = await send('not-a-token', {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/list',
      });

      expect(reply['status'], HttpStatus.ok);
      expect((reply['error']! as Map)['code'], -32001);
    });

    test(
      'a refusal comes back as a result the agent must read, not as a '
      'transport error it may never surface — and says whether to retry',
      () async {
        final token = server.mintTurnToken('chat-1');
        web.refuse = const RelayWebRefused('spent', retryable: false);

        final reply = await send(token, {
          'jsonrpc': '2.0',
          'id': 5,
          'method': 'tools/call',
          'params': {
            'name': 'web_search',
            'arguments': {'query': 'x'},
          },
        });

        final result = reply['result']! as Map<String, Object?>;
        expect(result['isError'], isTrue);
        expect(reply['error'], isNull);
        expect(_text(reply), 'spent Not worth retrying in this turn.');
      },
    );

    test(
      'a call with nothing to act on is refused without touching the grid',
      () async {
        final token = server.mintTurnToken('chat-1');

        final reply = await send(token, {
          'jsonrpc': '2.0',
          'id': 6,
          'method': 'tools/call',
          'params': {
            'name': 'web_fetch',
            'arguments': {'max_chars': 5},
          },
        });

        expect((reply['result']! as Map)['isError'], isTrue);
        expect(web.calls, isEmpty);
      },
    );

    test('on no grid the tools say so in the scripts\' own words, rather than '
        'posting nowhere', () async {
      final token = server.mintTurnToken('chat-1');
      grid = null;

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {
          'name': 'web_search',
          'arguments': {'query': 'x'},
        },
      });

      expect((reply['result']! as Map)['isError'], isTrue);
      expect(_text(reply), kWebNeedsGrid);
      expect(web.calls, isEmpty);
    });

    test('a notification is accepted and not answered — replying to one is a '
        'protocol error', () async {
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });

      expect(reply['status'], HttpStatus.accepted);
      expect(reply['result'], isNull);
    });

    test('bad input is a JSON-RPC error over HTTP 200, so an agent does not '
        'retry a request that may have already run', () async {
      final token = server.mintTurnToken('chat-1');

      final malformed = await sendRaw(token: token, body: '{');
      final wrongMethod = await sendRaw(
        token: token,
        body: '',
        method: 'DELETE',
      );

      expect(malformed['status'], HttpStatus.ok);
      expect((malformed['error']! as Map)['code'], -32700);
      expect(wrongMethod['status'], HttpStatus.ok);
      expect((wrongMethod['error']! as Map)['code'], -32600);
    });

    test('an internal failure is a JSON-RPC error over HTTP 200, so it cannot '
        'crash a long-running agent turn at the transport layer', () async {
      final token = server.mintTurnToken('chat-1');
      web.crash = StateError('boom');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'tools/call',
        'params': {
          'name': 'web_search',
          'arguments': {'query': 'x'},
        },
      });

      expect(reply['status'], HttpStatus.ok);
      expect(reply['id'], 9);
      expect((reply['error']! as Map)['code'], -32603);
    });
    test('a chat\'s next turn retires the last one\'s token, so a chat never '
        'has two live keys to itself', () async {
      final first = server.mintTurnToken('chat-1');
      final second = server.mintTurnToken('chat-1');

      expect(second, isNot(first));
      expect(
        (await send(first, {
          'jsonrpc': '2.0',
          'id': 7,
          'method': 'tools/list',
        }))['status'],
        HttpStatus.ok,
      );
      expect(
        (await send(second, {
          'jsonrpc': '2.0',
          'id': 8,
          'method': 'tools/list',
        }))['result'],
        isNotNull,
      );
    });

    /// Whether [token] is still allowed to use the tools.
    Future<bool> works(String token, int id) async =>
        (await send(token, {
          'jsonrpc': '2.0',
          'id': id,
          'method': 'tools/list',
        }))['result'] !=
        null;

    test(
      'a terminal session keeps its tools while the app sends turns into the '
      'same chat beside it — a turn token used to retire the session\'s, and '
      'the running CLI lost every Grid tool for good with one 401',
      () async {
        final session = server.mintSessionToken('chat-1');
        // A goal step, a loop beat, a scheduled task: all of them mint one.
        server.mintTurnToken('chat-1');
        server.mintTurnToken('chat-1');

        expect(await works(session, 20), isTrue);
      },
    );

    test('and the turns keep working beside the session, so neither lane is '
        'paying for the other', () async {
      final session = server.mintSessionToken('chat-1');
      final turn = server.mintTurnToken('chat-1');

      expect(await works(turn, 21), isTrue);
      expect(await works(session, 22), isTrue);
    });

    test('opening a second session for one chat retires the first, because a '
        'chat drives one CLI and the old one is gone', () async {
      final first = server.mintSessionToken('chat-1');
      final second = server.mintSessionToken('chat-1');

      expect(await works(first, 23), isFalse);
      expect(await works(second, 24), isTrue);
    });

    test('a session grant has no expiry of its own, so ending the session is '
        'the only thing that gives it back', () async {
      final session = server.mintSessionToken('chat-1');
      expect(await works(session, 25), isTrue);

      server.revoke(session);
      expect(await works(session, 26), isFalse);
    });

    test('one chat\'s session is no key to another\'s, whichever kind of grant '
        'the other holds', () async {
      final session = server.mintSessionToken('chat-1');
      server.mintSessionToken('chat-2');
      server.mintTurnToken('chat-2');

      expect(await works(session, 27), isTrue);
    });
  });

  group('ensureGridAgentScripts', () {
    late Directory into;

    setUp(() async {
      into = await Directory.systemTemp.createTemp('grid_agent_scripts');
    });
    tearDown(() => into.delete(recursive: true));

    test('writes every script the Hermes cards name', () async {
      await ensureGridAgentScripts(into: into);

      for (final name in gridAgentScripts().keys) {
        expect(File('${into.path}/$name').existsSync(), isTrue, reason: name);
      }
    });

    test('leaves an unchanged script alone, so "when did this change?" stays '
        'answerable', () async {
      await ensureGridAgentScripts(into: into);
      final file = File('${into.path}/serve.py');
      final before = file.lastModifiedSync();

      await ensureGridAgentScripts(into: into);

      expect(file.lastModifiedSync(), before);
    });

    test('removes a retired script an older install left behind', () async {
      // `browse.py` drove a headless Chromium and asked for a ~170 MB download
      // (public-repo ADR 0036 D-g). No guide names it any more — but a file an
      // agent can find is a file an agent can run, and not writing it leaves
      // every existing install with the old one.
      final stale = File('${into.path}/browse.py');
      await into.create(recursive: true);
      await stale.writeAsString('# the old browser fallback');

      await ensureGridAgentScripts(into: into);

      expect(stale.existsSync(), isFalse);
      expect(kRetiredGridAgentScripts, contains('browse.py'));
      expect(gridAgentScripts().keys, isNot(contains('browse.py')));
    });
  });
}

/// The one text block a tool result carries.
String _text(Map<String, Object?> reply) {
  final content = (reply['result']! as Map)['content']! as List;
  return (content.single as Map)['text']! as String;
}

/// A Browser tab that answers every verb, so the server's own routing and
/// refusals can be checked without an engine to draw a page with.
class _FakeBrowser implements GridBrowserAutomation {
  @override
  Future<GridBrowserAnswer> snapshot() async =>
      const GridBrowserAnswer('- button "Save" [ref=e1]');

  @override
  Future<GridBrowserAnswer> read({required int maxChars}) async =>
      const GridBrowserAnswer('the page');

  @override
  Future<GridBrowserAnswer> navigate(String url) async =>
      GridBrowserAnswer('Opened $url.');

  @override
  Future<GridBrowserAnswer> click(String ref) async =>
      GridBrowserAnswer('Clicked $ref.');

  @override
  Future<GridBrowserAnswer> type({
    required String ref,
    required String text,
    required bool submit,
  }) async => const GridBrowserAnswer('Typed.');

  @override
  Future<GridBrowserAnswer> back() async => const GridBrowserAnswer('Back.');

  @override
  Future<GridBrowserAnswer> screenshot() async => GridBrowserAnswer(
    'A picture of the page.',
    png: Uint8List.fromList(const [1, 2, 3]),
  );
}
