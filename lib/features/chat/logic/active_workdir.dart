import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/logic/agent_providers.dart';
import '../../projects/logic/project.dart';
import 'chat_sessions_controller.dart';

/// The folder the open chat runs in — its project's folder, or the app's default
/// workspace when the chat belongs to no project.
///
/// This is the same folder the agent gets as its working directory, so a file
/// the `@`-mention menu lists from here is one the agent can actually read.
final activeChatWorkdirProvider = Provider<String>((ref) {
  final sessions = ref.watch(chatSessionsProvider);
  final projectId =
      sessions.active?.projectId ??
      ref.read(chatSessionsProvider.notifier).draftProjectId;
  final project = ref.watch(projectByIdProvider(projectId));
  return project?.path ?? ref.watch(agentWorkspaceDirProvider).path;
});
