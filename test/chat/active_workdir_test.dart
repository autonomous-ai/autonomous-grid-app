import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/chat/logic/active_workdir.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/projects/logic/project.dart';

/// The folder the open chat runs in — where its agent works, its @-mention menu
/// lists, and the header's file browser opens. Resolving it wrong showed a plain
/// chat another project's files: the bug this guards against.
class _FixedSessions extends ChatSessionsController {
  _FixedSessions(this._state);

  final ChatSessionsState _state;

  @override
  ChatSessionsState build() => _state;
}

void main() {
  const workspace = '/home/.grid/app/agent-workspace';
  const project = Project(
    id: 'grid-apis',
    name: 'grid-apis',
    path: '/repo/grid-apis',
  );

  Conversation chat(String id, {String? projectId}) => Conversation(
    id: id,
    title: id,
    model: 'm',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    projectId: projectId,
  );

  ProviderContainer harness(ChatSessionsState state) {
    final container = ProviderContainer(
      overrides: [
        chatSessionsProvider.overrideWith(() => _FixedSessions(state)),
        projectByIdProvider(project.id).overrideWith((ref) => project),
        agentWorkspaceDirProvider.overrideWithValue(Directory(workspace)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a saved plain chat browses the app workspace — not the project the user '
      'drafted a new chat in just before opening it', () {
    // The exact shape of the bug: a loose chat is open, but a draft "New chat in
    // grid-apis" left draftProjectId set. It must not leak into a saved chat.
    final container = harness(
      ChatSessionsState(
        conversations: [chat('c1')],
        activeId: 'c1',
        draftProjectId: project.id,
      ),
    );
    expect(container.read(activeChatWorkdirProvider), workspace);
  });

  test('a chat that belongs to a project browses that project folder', () {
    final container = harness(
      ChatSessionsState(
        conversations: [chat('c1', projectId: project.id)],
        activeId: 'c1',
      ),
    );
    expect(container.read(activeChatWorkdirProvider), project.path);
  });

  test(
    'a new chat still being drafted in a project browses that project folder '
    'before the first message saves it',
    () {
      final container = harness(
        const ChatSessionsState(draftProjectId: 'grid-apis'),
      );
      expect(container.read(activeChatWorkdirProvider), project.path);
    },
  );

  test('a plain new chat, drafted in no project, browses the workspace', () {
    final container = harness(const ChatSessionsState());
    expect(container.read(activeChatWorkdirProvider), workspace);
  });

  // The label is what the header's browser and the Files panel's breadcrumb
  // both put over that folder. `agent-workspace` is a path the app picked, so a
  // loose chat must never be shown it.
  test('a loose chat names its folder "Workspace", never the path on disk', () {
    final container = harness(const ChatSessionsState());
    expect(container.read(activeChatWorkdirLabelProvider), 'Workspace');
  });

  test('a chat in a project names the folder after the project', () {
    final container = harness(
      ChatSessionsState(
        conversations: [chat('c1', projectId: project.id)],
        activeId: 'c1',
      ),
    );
    expect(container.read(activeChatWorkdirLabelProvider), project.name);
  });
}
