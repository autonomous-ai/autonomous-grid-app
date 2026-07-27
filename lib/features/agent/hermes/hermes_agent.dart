import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_version_service.dart';
import '../../playground/logic/chat_sender.dart';
import '../agent_definition.dart';
import '../common/agent_server_error.dart';
import 'hermes_chat_sender.dart';
import 'hermes_tool.dart';

/// Hermes — an agent loop the app spawns over ACP, using the user's own model
/// and tools. The default chat agent and the one that always has somewhere to
/// go: it speaks both wire dialects, so it runs wherever a chat model does.
final class HermesAgent extends AgentDefinition {
  const HermesAgent();

  @override
  String get id => 'hermes';

  @override
  String get name => 'Hermes';

  @override
  String get tagline => 'Runs locally. Uses your model and tools.';

  @override
  String get iconAsset => 'assets/agents/hermes_icon.webp';

  @override
  bool get needsResponses => false;

  @override
  bool installed(Ref ref) => ref.watch(hermesInstalledProvider);

  @override
  Future<String?> version(Ref ref) => ref.watch(hermesVersionProvider.future);

  @override
  void reprobe(Ref ref) {
    ref.invalidate(hermesPathProvider);
    ref.invalidate(hermesVersionProvider);
  }

  @override
  ChatSender sender(Ref ref) => ref.watch(hermesChatSenderProvider);

  /// Make sure Hermes can actually serve ACP — the mode chat drives it in. An
  /// older `grid` CLI installs Hermes without that piece, so this finishes the
  /// job on install *and* repairs such a machine on update. The raw reason is
  /// logged by the repair itself; this is only the line the user reads.
  @override
  Future<String?> finishInstall(Ref ref) async {
    final setup = ref.read(hermesAcpSetupProvider);
    if (setup == null || await setup.isReady()) return null;
    return await setup.repair() == null
        ? null
        : '$kAgentSetupUnfinished Check your internet connection, then try '
              'again.';
  }
}
