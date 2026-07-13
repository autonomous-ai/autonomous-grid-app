import 'package:flutter/foundation.dart' show kDebugMode;
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

  /// Whether the user may pick this backend.
  ///
  /// Codex is hidden from shipped builds: codex ≥ 0.141 talks only to the
  /// Responses API, while the grid relay and the local engine serve Chat
  /// Completions, so every Codex send fails with a 404 on `/v1/responses`.
  /// Offering it would be a lie. Kept selectable in debug so it can be tried
  /// again the day the relay grows a `/v1/responses` endpoint.
  /// TODO(BE): re-enable once the relay serves the Responses API.
  bool get isSelectable => this != AgentBackend.codex || kDebugMode;

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
    // Don't resume onto a backend the user can no longer pick (Codex outside a
    // debug build) — the picker would read "on" while every send failed.
    if (!saved.isSelectable) return AgentBackend.off;
    final tool = saved.tool;
    // Same for a backend whose tool was since removed. Start Off and let the
    // user re-arm it (which re-runs the install flow).
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
