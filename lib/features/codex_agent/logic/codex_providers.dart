import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/codex_agent_service.dart';
import '../../../infrastructure/cli/codex_event.dart';
import '../../../infrastructure/cli/codex_resolver.dart';

/// Locates the `codex` binary. Invalidate [codexPathProvider] to re-probe after
/// an install.
final codexResolverProvider = Provider<CodexResolver>((ref) => CodexResolver());

/// Absolute path to `codex`, or null when it isn't installed.
final codexPathProvider = Provider<String?>(
  (ref) => ref.watch(codexResolverProvider).resolve(),
);

/// Whether the Agent-mode backend (codex) is installed on this computer.
final codexInstalledProvider = Provider<bool>(
  (ref) => ref.watch(codexPathProvider) != null,
);

/// The codex seam, or null when codex is absent (the sender then reports a
/// friendly "install Codex" line instead of spawning nothing).
final codexAgentServiceProvider = Provider<CodexAgentService?>((ref) {
  final path = ref.watch(codexPathProvider);
  return path == null ? null : CodexAgentServiceImpl(path);
});

/// The read-only working root the agent runs in, created on first read.
final codexWorkspaceDirProvider = Provider<Directory>((ref) {
  final dir = GridPaths.codexWorkspaceDir;
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
});

/// Whether the Chat tab's experimental Agent mode is on. In-memory for now —
/// each session starts with it off. `ChatSessionsController` reads this to route
/// a send to codex instead of the normal chat relay.
final codexAgentEnabledProvider = NotifierProvider<CodexAgentToggle, bool>(
  CodexAgentToggle.new,
);

class CodexAgentToggle extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// The live activity feed of the in-flight Agent run — the shell commands and
/// tool calls the agent runs, newest appended last. The Agent working bubble
/// watches this; [CodexChatSender] clears it at the start of each send and
/// upserts each step as codex reports it.
final codexActivityProvider =
    NotifierProvider<CodexActivityLog, List<CodexActivity>>(
      CodexActivityLog.new,
    );

class CodexActivityLog extends Notifier<List<CodexActivity>> {
  @override
  List<CodexActivity> build() => const [];

  void clear() => state = const [];

  /// Insert a new step, or replace the existing one with the same id (a
  /// `started` step transitioning to `completed`).
  void upsert(CodexActivity activity) {
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
