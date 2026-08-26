import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_chat_surface.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
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
      'Hermes has no program to open, so it stays a message list whatever is '
      'asked of it — offering a terminal it cannot draw would be a lie on '
      'screen',
      () {
        expect(agentChatSurface(AgentTool.hermes), AgentChatSurface.list);
        expect(
          agentChatSurface(AgentTool.hermes, chosen: AgentChatSurface.terminal),
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

    test('an agent nobody has set follows its default', () {
      expect(
        container.read(agentChatSurfaceProvider(AgentTool.claude)),
        AgentChatSurface.terminal,
      );
    });

    test('setting one agent moves that agent and no other — the default is per '
        'agent, so Codex must not follow a choice made about Claude Code', () {
      container
          .read(chatPrefsProvider.notifier)
          .setAgentSurface(AgentTool.claude.id, AgentChatSurface.list);

      expect(
        container.read(agentChatSurfaceProvider(AgentTool.claude)),
        AgentChatSurface.list,
      );
      expect(
        container.read(agentChatSurfaceProvider(AgentTool.codex)),
        AgentChatSurface.terminal,
      );
    });

    test(
      'the choice survives a restart, and only the agents actually changed are '
      'written down — an untouched agent must keep following the default '
      'rather than freezing today\'s',
      () {
        container
            .read(chatPrefsProvider.notifier)
            .setAgentSurface(AgentTool.codex.id, AgentChatSurface.list);

        final reread = ChatPrefsStore(
          file: File('${dir.path}/chat_prefs.json'),
        ).load();

        expect(reread.agentSurface, {
          AgentTool.codex.id: AgentChatSurface.list,
        });
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
      'a chat saved before the setting existed reads back as no choice at all, '
      'and so keeps the shape it has always had',
      () {
        final legacy = Conversation.fromJson({
          'id': '1',
          'title': 'Old chat',
          'model': 'qwen',
          'createdAt': '2026-08-01T00:00:00Z',
          'updatedAt': '2026-08-01T00:00:00Z',
        });

        expect(legacy.surface, isNull);
        expect(
          agentChatSurface(AgentTool.claude, chosen: legacy.surface),
          AgentChatSurface.terminal,
        );
      },
    );

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
