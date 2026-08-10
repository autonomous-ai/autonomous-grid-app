import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_providers.dart';
import 'chat_scope.dart';

/// The folder the open chat runs in — its project's folder, or the app's default
/// workspace when the chat belongs to no project.
///
/// This is the same folder the agent gets as its working directory, so a file
/// the `@`-mention menu lists (or the header's file browser opens) is one the
/// agent can actually read.
///
/// Reads the open chat's project through [openChatProjectProvider] — the same
/// scope the assistant and model choices follow, so the folder, who answers in
/// it and what they answer with can never describe different projects.
final activeChatWorkdirProvider = Provider<String>((ref) {
  final project = ref.watch(openChatProjectProvider);
  return project?.path ?? ref.watch(agentWorkspaceDirProvider).path;
});
