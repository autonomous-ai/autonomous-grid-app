import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playground/logic/chat_sender.dart';
import '../agent_definition.dart';
import 'codex_chat_sender.dart';
import 'codex_tool.dart';

/// Codex — OpenAI's coding agent, run over `codex exec --json`. Reachable only
/// over the Responses API, so it runs on a grid that serves it and hands the
/// chat back on one that doesn't (see `agentRunsOnGrid`). Needs no post-install
/// repair, so it inherits the no-op [finishInstall].
final class CodexAgent extends AgentDefinition {
  const CodexAgent();

  @override
  String get id => 'codex';

  @override
  String get name => 'Codex';

  @override
  String get tagline => "OpenAI's coding agent.";

  @override
  String get iconAsset => 'assets/agents/codex_icon.png';

  @override
  bool get needsResponses => true;

  @override
  bool installed(Ref ref) => ref.watch(codexInstalledProvider);

  @override
  Future<String?> version(Ref ref) => ref.watch(codexVersionProvider.future);

  @override
  void reprobe(Ref ref) {
    ref.invalidate(codexPathProvider);
    ref.invalidate(codexVersionProvider);
  }

  @override
  ChatSender sender(Ref ref) => ref.watch(codexChatSenderProvider);
}
