import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The selected Chat-tab agent backend. In-memory — each session starts Off.
/// `ChatSessionsController` reads this to route a send to codex/hermes instead
/// of the normal chat relay.
final agentBackendProvider =
    NotifierProvider<AgentBackendController, AgentBackend>(
      AgentBackendController.new,
    );

class AgentBackendController extends Notifier<AgentBackend> {
  @override
  AgentBackend build() => AgentBackend.off;

  void set(AgentBackend backend) => state = backend;
}
