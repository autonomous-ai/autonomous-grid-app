import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_acp_setup.dart';
import '../../../infrastructure/cli/host_environment.dart';
import '../../../infrastructure/logging/app_log.dart';

/// The agent that answers chat: Hermes, an agent loop the app spawns and streams
/// into the conversation. The app installs it — a `uv` tool on a private
/// CPython inside `~/.grid`, part of first-run setup — and finds it on the
/// augmented PATH; there's no bundled sidecar and nothing for the user to pick.
const String hermesExecutable = 'hermes';

/// Absolute path to the Hermes binary, or null when it isn't installed yet.
/// Invalidate to re-probe after an install.
final hermesPathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable(hermesExecutable),
);

/// Whether Hermes is installed on this computer. A machine without it still
/// chats — the turn goes straight to the grid's chat API instead.
final hermesInstalledProvider = Provider<bool>(
  (ref) => ref.watch(hermesPathProvider) != null,
);

/// Reads and repairs Hermes's ACP support, or null when Hermes isn't installed
/// at all — there is nothing to repair until the CLI has put it here.
///
/// Kept beside [hermesPathProvider] so a repair always drives the same binary
/// the rest of the app found, and re-probing after an install swaps both.
final hermesAcpSetupProvider = Provider<HermesAcpSetup?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null
      ? null
      : HermesAcpSetupImpl(path, log: ref.watch(appLogProvider));
});
