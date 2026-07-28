import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/logic/agent_providers.dart';
import '../../projects/logic/project.dart';
import 'chat_sessions_controller.dart';

/// The folder the open chat runs in — its project's folder, or the app's default
/// workspace when the chat belongs to no project.
///
/// This is the same folder the agent gets as its working directory, so a file
/// the `@`-mention menu lists (or the header's file browser opens) is one the
/// agent can actually read.
///
/// Resolves the project through [ChatSessionsState.openProjectId], not
/// `active?.projectId ?? draftProjectId`: the draft folder belongs only to a
/// *new* chat still being composed. On a saved loose chat, falling through to it
/// pointed the folder at whichever project the user last drafted in — showing a
/// plain chat another project's files.
final activeChatWorkdirProvider = Provider<String>((ref) {
  final projectId = ref.watch(
    chatSessionsProvider.select((s) => s.openProjectId),
  );
  final project = ref.watch(projectByIdProvider(projectId));
  return project?.path ?? ref.watch(agentWorkspaceDirProvider).path;
});
