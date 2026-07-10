import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import 'agent_tool.dart';

/// Which backend drives a Chat-tab send. [off] uses the normal grid chat relay;
/// [codex] and [hermes] each run their CLI agent loop and stream the reply back
/// through the shared `ChatSender` seam.
enum AgentBackend { off, codex, hermes }

extension AgentBackendX on AgentBackend {
  /// Short label for the picker.
  String get label => switch (this) {
    AgentBackend.off => 'Agent',
    AgentBackend.codex => 'Codex',
    AgentBackend.hermes => 'Hermes',
  };

  bool get isOn => this != AgentBackend.off;

  /// The tool that backs this backend, or null for [off].
  AgentTool? get tool => switch (this) {
    AgentBackend.off => null,
    AgentBackend.codex => AgentTool.codex,
    AgentBackend.hermes => AgentTool.hermes,
  };
}

/// The selected Chat-tab agent backend. Restored from the last session, so a
/// user who left Agent on comes back to it. `ChatSessionsController` reads this
/// to route a send to codex/hermes instead of the normal chat relay.
final agentBackendProvider =
    NotifierProvider<AgentBackendController, AgentBackend>(
      AgentBackendController.new,
    );

class AgentBackendController extends Notifier<AgentBackend> {
  @override
  AgentBackend build() {
    final saved = _parse(ref.read(chatPrefsProvider).agent);
    final tool = saved.tool;
    // Don't resume onto a backend whose tool was since removed — that would show
    // the picker "on" while every send failed. Start Off and let the user re-arm
    // it (which re-runs the install flow).
    if (tool != null && !ref.read(agentToolInstalledProvider(tool))) {
      return AgentBackend.off;
    }
    return saved;
  }

  void set(AgentBackend backend) {
    state = backend;
    ref.read(chatPrefsProvider.notifier).setAgent(backend.name);
  }

  AgentBackend _parse(String? name) => AgentBackend.values.firstWhere(
    (b) => b.name == name,
    orElse: () => AgentBackend.off,
  );
}
