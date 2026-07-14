import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_environment.dart';

/// The agent that answers chat: Hermes, an agent loop the app spawns and streams
/// into the conversation. The `grid` CLI installs it
/// (`grid agent install hermes`, part of first-run setup) and it's found on the
/// augmented PATH — there's no bundled sidecar and nothing for the user to pick.
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
