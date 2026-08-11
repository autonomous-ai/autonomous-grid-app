import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_providers.dart';
import 'chat_scope.dart';

/// The folder the open chat runs in — its project's folder, or the app's default
/// workspace when the chat belongs to no project.
///
/// This is the same folder the agent gets as its working directory, so a file
/// the `@`-mention menu lists (or the Files panel browses) is one the agent can
/// actually read.
///
/// Reads the open chat's project through [openChatProjectProvider] — the same
/// scope the assistant and model choices follow, so the folder, who answers in
/// it and what they answer with can never describe different projects.
final activeChatWorkdirProvider = Provider<String>((ref) {
  final project = ref.watch(openChatProjectProvider);
  return project?.path ?? ref.watch(agentWorkspaceDirProvider).path;
});

/// What that folder is called on screen — the app folder's name, since
/// `agent-workspace` is a path we chose and not a word the user knows.
const kChatWorkspaceLabel = 'Workspace';

/// What to call [activeChatWorkdirProvider] wherever it is shown: the project's
/// own name, or [kChatWorkspaceLabel] for the folder a chat with no project runs
/// in.
///
/// Derived here rather than at each screen so the Files panel's breadcrumb and
/// anything after it name one folder one way.
final activeChatWorkdirLabelProvider = Provider<String>(
  (ref) => ref.watch(openChatProjectProvider)?.name ?? kChatWorkspaceLabel,
);
