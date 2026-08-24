import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_command.dart';
import 'package:grid_app/infrastructure/mcp/grid_agent_scripts.dart';
import 'package:grid_app/infrastructure/mcp/grid_mcp_server.dart';
import 'package:grid_app/infrastructure/mcp/grid_mcp_tools.dart';

void main() {
  group('readGridAsk', () {
    test('reads the command line an agent asked for', () {
      final outcome = readGridAsk({'run': '/loop 30m check the build'});

      expect(outcome, isA<GridAskAccepted>());
      final call = (outcome as GridAskAccepted).call;
      expect(call.command, ChatCommand.loop);
      expect(call.argument, '30m check the build');
    });

    test('refuses a command the user alone may type — an assistant that could '
        'clear the transcript has a way out of every hard turn', () {
      final outcome = readGridAsk({'run': '/clear'});

      expect(outcome, isA<GridAskRefused>());
      expect((outcome as GridAskRefused).message, contains('/loop'));
    });

    test('refuses an empty or missing argument with what to send instead, '
        'because the agent has to answer the user either way', () {
      expect(readGridAsk(const {}), isA<GridAskRefused>());
      expect(readGridAsk({'run': '   '}), isA<GridAskRefused>());
      expect(readGridAsk('/loop 5m'), isA<GridAskRefused>());
    });

    test('refuses something that is no command at all rather than guessing — '
        'guessing at a sentence is what the fenced block did wrong', () {
      final outcome = readGridAsk({'run': 'please keep checking'});

      expect(outcome, isA<GridAskRefused>());
    });
  });

  group('skillCardBody', () {
    test('drops the front-matter, which is retrieval metadata for a folder of '
        'files that no longer exists over MCP', () {
      const card = '---\nname: x\ndescription: y\n---\n\n# Heading\n\nBody.\n';

      expect(skillCardBody(card), '# Heading\n\nBody.');
    });

    test('a card with no front-matter is its own body', () {
      expect(skillCardBody('# Heading\n'), '# Heading');
    });
  });

  group('GridMcpServer', () {
    late GridMcpServer server;
    late List<(String, ChatCommandCall)> ran;

    setUp(() async {
      ran = [];
      server = GridMcpServer(
        onAsk: (chatId, call) async {
          ran.add((chatId, call));
          return 'Repeating every 30m.';
        },
      );
      await server.start();
    });
    tearDown(() => server.stop());

    Future<Map<String, Object?>> send(
      String token,
      Map<String, Object?> body,
    ) async {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse(server.url!));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      client.close();
      return {
        'status': response.statusCode,
        if (text.isNotEmpty) ...jsonDecode(text) as Map<String, Object?>,
      };
    }

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
      expect(tools, ['grid_ask', 'grid_guide']);
    });

    test('a token speaks for one chat — a turn in one conversation can never '
        'start a loop in another', () async {
      final token = server.mintTurnToken('chat-1');

      await send(token, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'grid_ask',
          'arguments': {'run': '/loop 30m check the build'},
        },
      });

      expect(ran.single.$1, 'chat-1');
      expect(ran.single.$2.command, ChatCommand.loop);
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

        expect(reply['status'], HttpStatus.unauthorized);
        expect(ran, isEmpty);
      },
    );

    test('an unknown token is refused, so nothing else on this machine can '
        'drive somebody\'s chat by guessing the port', () async {
      final reply = await send('not-a-token', {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/list',
      });

      expect(reply['status'], HttpStatus.unauthorized);
    });

    test('a refused ask comes back as a result the agent must read, not as a '
        'transport error it may never surface to the user', () async {
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {
          'name': 'grid_ask',
          'arguments': {'run': '/compact'},
        },
      });

      final result = reply['result']! as Map<String, Object?>;
      expect(result['isError'], isTrue);
      expect(reply['error'], isNull);
      expect(ran, isEmpty);
    });

    test('a guide comes back without its front-matter', () async {
      final token = server.mintTurnToken('chat-1');

      final reply = await send(token, {
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'tools/call',
        'params': {
          'name': 'grid_guide',
          'arguments': {'topic': 'delegate'},
        },
      });

      final content = (reply['result']! as Map)['content']! as List;
      final text = (content.single as Map)['text']! as String;
      expect(text, isNot(contains('name: grid-delegate')));
      expect(text, contains('run_in_background'));
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
        HttpStatus.unauthorized,
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
  });

  group('the guides', () {
    test('every topic the tool offers has a body, and every body is offered — '
        'a schema and a map that disagree fail as a tool call the model was '
        'told it could make', () {
      final offered =
          ((kGridGuideTool.schema['properties']! as Map)['topic']!
                  as Map)['enum']!
              as List;

      expect(offered.toSet(), kGridGuides.keys.toSet());
    });

    test('the ones that name scripts point into Grid\'s own folder, never into '
        'an agent\'s — the scripts moving is what let the cards leave', () {
      for (final topic in ['web', 'research', 'serve']) {
        final body = kGridGuides[topic]!;
        expect(body, contains('/app/agent-scripts/'), reason: topic);
        expect(body, isNot(contains('.codex/skills')), reason: topic);
        expect(body, isNot(contains('.claude/skills')), reason: topic);
      }
    });

    test('no guide still carries its front-matter, which named a file the '
        'agent can no longer open', () {
      for (final entry in kGridGuides.entries) {
        expect(entry.value, isNot(startsWith('---')), reason: entry.key);
        expect(
          entry.value,
          isNot(contains('\nname: grid-')),
          reason: entry.key,
        );
      }
    });
  });

  group('ensureGridAgentScripts', () {
    late Directory into;

    setUp(() async {
      into = await Directory.systemTemp.createTemp('grid_agent_scripts');
    });
    tearDown(() => into.delete(recursive: true));

    test('writes every script a guide names', () async {
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
  });
}
