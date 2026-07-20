import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../agent/logic/codex_chat_sender.dart';
import '../../agent/logic/hermes_chat_sender.dart';
import '../../playground/logic/chat_sender.dart';
import 'agent_catalog.dart';
import 'agent_status.dart';

/// The agent that answers chats right now — the user's remembered choice when
/// it's installed, else any installed agent so chat still has one, else the
/// catalog default.
///
/// Resolving against what's *installed* keeps the app honest: a saved choice for
/// an agent the user later removed can't leave chat pointed at an agent that
/// isn't there.
final activeChatAgentProvider = Provider<AgentTool>((ref) {
  final chosen = ref.watch(chatPrefsProvider.select((p) => p.chatAgent));
  // The chosen agent, if it's one we know and it's installed.
  for (final tool in AgentTool.values) {
    if (tool.id == chosen && ref.watch(agentInstalledProvider(tool))) {
      return tool;
    }
  }
  // The choice isn't available — fall back to any installed agent.
  for (final tool in AgentTool.values) {
    if (ref.watch(agentInstalledProvider(tool))) return tool;
  }
  return kChatAgent;
});

/// The [ChatSender] for whichever agent is answering chats — the seam chat
/// routing reads so it never has to know which agent is behind the reply.
final chatAgentSenderProvider = Provider<ChatSender>((ref) {
  return switch (ref.watch(activeChatAgentProvider)) {
    AgentTool.codex => ref.watch(codexChatSenderProvider),
    // Hermes is the default; openclaw can't be active (never installed) but the
    // switch stays exhaustive, and Hermes is the safe fallback for it.
    AgentTool.hermes ||
    AgentTool.openclaw => ref.watch(hermesChatSenderProvider),
  };
});
