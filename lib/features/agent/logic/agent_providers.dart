import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/agent_event.dart';

/// The read-only working root the agent runs in, created on first read.
final agentWorkspaceDirProvider = Provider<Directory>((ref) {
  final dir = GridPaths.agentWorkspaceDir;
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
});

/// The live activity feed of the in-flight agent run — the shell commands and
/// tool calls the agent runs, newest appended last. The "agent is working"
/// bubble watches this; `HermesChatSender` clears it at the start of each send
/// and upserts each step as Hermes reports it over ACP.
final agentActivityProvider =
    NotifierProvider<AgentActivityLog, List<AgentActivity>>(
      AgentActivityLog.new,
    );

class AgentActivityLog extends Notifier<List<AgentActivity>> {
  @override
  List<AgentActivity> build() => const [];

  void clear() => state = const [];

  /// Insert a new step, or replace the existing one with the same id (a
  /// `started` step transitioning to `completed`).
  void upsert(AgentActivity activity) {
    final index = state.indexWhere((step) => step.id == activity.id);
    if (index == -1) {
      state = [...state, activity];
      return;
    }
    final next = [...state];
    next[index] = activity;
    state = List.unmodifiable(next);
  }
}
