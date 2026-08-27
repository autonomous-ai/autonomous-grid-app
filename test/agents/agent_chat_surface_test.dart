import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_chat_surface.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

void main() {
  group('which surface an agent draws in', () {
    test('the two agents with a program of their own open in it, so a user who '
        'never touches the setting sees what this build has always shown', () {
      expect(agentChatSurface(AgentTool.claude), AgentChatSurface.terminal);
      expect(agentChatSurface(AgentTool.codex), AgentChatSurface.terminal);
    });

    test(
      'Hermes draws its own program like the other two — `hermes --tui` exists '
      'as of 0.20.5, so the capability is no longer what separates it',
      () {
        expect(agentChatSurface(AgentTool.hermes), AgentChatSurface.terminal);
        expect(
          agentChatSurface(AgentTool.hermes, chosen: AgentChatSurface.terminal),
          AgentChatSurface.terminal,
        );
      },
    );

    test(
      'a computer that cannot run the program stays a message list whatever is '
      'asked of it — offering a terminal it cannot draw would be a lie on '
      'screen',
      () {
        expect(
          agentChatSurface(AgentTool.hermes, terminalAvailable: false),
          AgentChatSurface.list,
        );
        expect(
          agentChatSurface(
            AgentTool.hermes,
            chosen: AgentChatSurface.terminal,
            terminalAvailable: false,
          ),
          AgentChatSurface.list,
        );
      },
    );

    test('a choice made for an agent that can honour it is honoured', () {
      expect(
        agentChatSurface(AgentTool.claude, chosen: AgentChatSurface.list),
        AgentChatSurface.list,
      );
      expect(
        agentChatSurface(AgentTool.codex, chosen: AgentChatSurface.terminal),
        AgentChatSurface.terminal,
      );
    });
  });

  group('the setting reaches new chats and leaves old ones alone', () {
    late Directory dir;
    late ProviderContainer container;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('agent-surface-');
      container = ProviderContainer(
        overrides: [
          chatPrefsStoreProvider.overrideWithValue(
            ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
          ),
        ],
      );
    });

    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });

    test('a fresh install opens chats as messages — the terminal gives up the '
        'step feed, the plan, the Open button and the transcript, so it is a '
        'choice to make rather than one to be handed', () {
      expect(
        container.read(agentChatSurfaceProvider(AgentTool.claude)),
        AgentChatSurface.list,
      );
      expect(
        container.read(agentChatSurfaceProvider(AgentTool.codex)),
        AgentChatSurface.list,
      );
    });

    test('the setting still reaches every agent that can honour it', () {
      container
          .read(chatPrefsProvider.notifier)
          .setChatSurface(AgentChatSurface.terminal);

      expect(
        container.read(agentChatSurfaceProvider(AgentTool.claude)),
        AgentChatSurface.terminal,
      );
      expect(
        container.read(agentChatSurfaceProvider(AgentTool.codex)),
        AgentChatSurface.terminal,
      );
    });

    test(
      'one setting moves every agent that can follow it — it is set once '
      'on Appearance, so Codex must not keep a shape Claude Code has left',
      () {
        container
            .read(chatPrefsProvider.notifier)
            .setChatSurface(AgentChatSurface.list);

        expect(
          container.read(agentChatSurfaceProvider(AgentTool.claude)),
          AgentChatSurface.list,
        );
        expect(
          container.read(agentChatSurfaceProvider(AgentTool.codex)),
          AgentChatSurface.list,
        );
      },
    );

    test(
      'on a Mac that cannot run Hermes\'s own program, Hermes stays a message '
      'list whatever the setting says — but only once the probe has said so, '
      'because a chat that flips shape while the probe runs reads as a bug',
      () async {
        final probed = ProviderContainer(
          overrides: [
            chatPrefsStoreProvider.overrideWithValue(
              ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
            ),
            hermesTuiReadyProvider.overrideWith((ref) async => false),
          ],
        );
        addTearDown(probed.dispose);
        probed
            .read(chatPrefsProvider.notifier)
            .setChatSurface(AgentChatSurface.terminal);

        expect(
          probed.read(agentChatSurfaceProvider(AgentTool.hermes)),
          AgentChatSurface.terminal,
        );
        await probed.read(hermesTuiReadyProvider.future);
        expect(
          probed.read(agentChatSurfaceProvider(AgentTool.hermes)),
          AgentChatSurface.list,
        );
      },
    );

    test('the choice survives a restart', () {
      container
          .read(chatPrefsProvider.notifier)
          .setChatSurface(AgentChatSurface.list);

      final reread = ChatPrefsStore(
        file: File('${dir.path}/chat_prefs.json'),
      ).load();

      expect(reread.chatSurface, AgentChatSurface.list);
    });

    test(
      'a surface this build no longer knows lands where a fresh install does, '
      'not somewhere odd',
      () {
        File(
          '${dir.path}/chat_prefs.json',
        ).writeAsStringSync('{"chatSurface": "hologram"}');

        final reread = ChatPrefsStore(
          file: File('${dir.path}/chat_prefs.json'),
        ).load();

        expect(reread.chatSurface, AgentChatSurface.list);
      },
    );
  });

  group('a chat keeps the shape it started in', () {
    test(
      'a chat that started as a terminal stays one whatever the setting later '
      'says — its conversation lives in the CLI session, so redrawing it as a '
      'message list would show an empty transcript in place of the chat',
      () {
        final now = DateTime.now();
        final started = Conversation(
          id: '1',
          title: 'Chat',
          model: 'qwen',
          createdAt: now,
          updatedAt: now,
          agent: AgentTool.claude.id,
          surface: AgentChatSurface.terminal,
        );

        expect(
          agentChatSurface(AgentTool.claude, chosen: started.surface),
          AgentChatSurface.terminal,
        );
      },
    );

    test(
      'a chat that recorded nothing and has an empty transcript still opens as '
      'a terminal, even though a fresh install now ships the message list — '
      'those are the terminal chats from before the record began, and the '
      'shipped default would redraw them as an empty page',
      () {
        final legacy = Conversation.fromJson({
          'id': '1',
          'title': 'Old chat',
          'model': 'qwen',
          'createdAt': '2026-08-01T00:00:00Z',
          'updatedAt': '2026-08-01T00:00:00Z',
        });

        expect(legacy.surface, isNull);
        expect(recordedChatSurface(legacy), isNull);
        expect(
          agentChatSurface(AgentTool.claude, chosen: legacy.surface),
          AgentChatSurface.terminal,
        );
      },
    );

    test(
      'a chat saved before the setting existed with a transcript is a message '
      'list, whatever its agent opens in today — a terminal chat writes no '
      'messages, so the messages are the proof, and defaulting it to the '
      'terminal put 188 of them nowhere on screen',
      () {
        final legacy =
            Conversation.fromJson({
              'id': '1',
              'title': 'Old chat',
              'model': 'qwen',
              'agent': AgentTool.claude.id,
              'createdAt': '2026-08-01T00:00:00Z',
              'updatedAt': '2026-08-01T00:00:00Z',
            }).copyWith(
              messages: const [ChatMessage(role: ChatRole.user, text: 'hi')],
            );

        expect(recordedChatSurface(legacy), AgentChatSurface.list);
        expect(
          agentChatSurface(
            AgentTool.claude,
            chosen: recordedChatSurface(legacy),
          ),
          AgentChatSurface.list,
        );
      },
    );

    test('a recorded surface outranks the transcript — a chat born a terminal '
        'stays one even if a turn lands in its messages', () {
      final chat =
          Conversation.fromJson({
            'id': '1',
            'title': 'Chat',
            'model': 'qwen',
            'surface': 'terminal',
            'createdAt': '2026-08-26T00:00:00Z',
            'updatedAt': '2026-08-26T00:00:00Z',
          }).copyWith(
            messages: const [ChatMessage(role: ChatRole.user, text: 'hi')],
          );

      expect(recordedChatSurface(chat), AgentChatSurface.terminal);
    });

    test(
      'a surface this build no longer knows reads as no choice rather than as '
      'the wrong one: guessing would show an empty transcript where the '
      'conversation is',
      () {
        final odd = Conversation.fromJson({
          'id': '1',
          'title': 'Odd chat',
          'model': 'qwen',
          'surface': 'hologram',
          'createdAt': '2026-08-01T00:00:00Z',
          'updatedAt': '2026-08-01T00:00:00Z',
        });

        expect(odd.surface, isNull);
      },
    );

    test('a recorded surface round-trips through the chat file', () {
      final chat = Conversation.fromJson({
        'id': '1',
        'title': 'Chat',
        'model': 'qwen',
        'createdAt': '2026-08-01T00:00:00Z',
        'updatedAt': '2026-08-01T00:00:00Z',
      }).copyWith(surface: AgentChatSurface.list);

      expect(
        Conversation.fromJson(chat.toJson()).surface,
        AgentChatSurface.list,
      );
    });
  });
}
