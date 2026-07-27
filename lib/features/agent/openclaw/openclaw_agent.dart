import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_installer.dart';
import '../../playground/logic/chat_sender.dart';
import '../agent_definition.dart';
import 'openclaw_chat_sender.dart';
import 'openclaw_tool.dart';

/// OpenClaw — a local agent driven over `openclaw infer model run`. It speaks
/// chat-completions to the grid (Grid writes itself in as an `openai-completions`
/// provider), so it runs wherever a chat model does.
///
/// **Developer-only** ([devOnly]): the transport is wired to OpenClaw's
/// documented CLI but hasn't been verified against a live binary, and the shape
/// of its `--json` reply is inferred from the docs — so it's kept out of shipped
/// releases until it's confirmed, rather than shown to a user as an agent that
/// might not answer.
final class OpenClawAgent extends AgentDefinition {
  const OpenClawAgent();

  @override
  String get id => 'openclaw';

  @override
  String get name => 'OpenClaw';

  @override
  String get tagline => 'Runs locally over its own CLI.';

  @override
  String get iconAsset => 'assets/agents/openclaw_icon.png';

  @override
  bool get needsResponses => false;

  @override
  bool get devOnly => true;

  /// OpenClaw isn't a self-contained binary — it installs as an npm global. The
  /// app runs that command on an explicit click; it lands in npm's global bin
  /// (which needs to be on PATH for the app to find it), so OpenClaw stays
  /// developer-only until that's proven out.
  @override
  AgentInstallSpec get installSpec =>
      const CommandInstall(['npm', 'i', '-g', 'openclaw@latest']);

  @override
  bool installed(Ref ref) => ref.watch(openClawInstalledProvider);

  @override
  Future<String?> version(Ref ref) => ref.watch(openClawVersionProvider.future);

  @override
  void reprobe(Ref ref) {
    ref.invalidate(openClawPathProvider);
    ref.invalidate(openClawVersionProvider);
  }

  @override
  ChatSender sender(Ref ref) => ref.watch(openClawChatSenderProvider);
}
