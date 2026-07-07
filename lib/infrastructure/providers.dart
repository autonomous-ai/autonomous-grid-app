import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_environment.dart';
import 'cli/command_log.dart';
import 'cli/file_logging_grid_cli_service.dart';
import 'cli/grid_cli_service.dart';
import 'cli/grid_cli_service_impl.dart';
import 'cli/grid_resolver.dart';
import 'cli/logging_grid_cli_service.dart';
import 'cli/remote_mode_grid_cli_service.dart';
import 'logging/cli_log.dart';
import 'state/grid_home_store.dart';

/// Locates the `grid` binary (sidecar → GRID_BIN → PATH). A user-configured
/// path from settings gets threaded in here later.
final gridResolverProvider = Provider<GridResolver>((ref) => GridResolver());

/// Absolute path to `grid`, or null when it cannot be found.
final gridPathProvider =
    Provider<String?>((ref) => ref.watch(gridResolverProvider).resolve());

/// The CLI seam. Null when `grid` is absent — preflight gates the rest of the
/// app on this being non-null. Override with [FakeGridCliService] in dev/test.
/// Pinned to remote mode via [RemoteModeGridCliService] (the app is a
/// remote-only client), wrapped in [LoggingGridCliService] so every command
/// shows up in the Debug tab, and in [FileLoggingGridCliService] so it is also
/// appended to a durable transcript (`~/.grid/logs/app_cli.log`).
final gridCliServiceProvider = Provider<GridCliService?>((ref) {
  final path = ref.watch(gridPathProvider);
  if (path == null) return null;
  final recorder = ref.read(commandLogProvider.notifier);
  final fileLog = ref.read(cliLogProvider);
  return RemoteModeGridCliService(
    LoggingGridCliService(
      FileLoggingGridCliService(GridCliServiceImpl(path), fileLog),
      recorder,
    ),
  );
});

/// Reads state from `~/.grid` (nguồn 1). Read-only; mutations go through the CLI.
final gridHomeStoreProvider =
    Provider<GridHomeStore>((ref) => const GridHomeStore());

/// Control-plane base URL for the app's direct HTTP calls (managed-network
/// create, etc.). The CLI reads its own API URL from `~/.grid`, so this is no
/// longer threaded into `grid login`. Resolves to prod in release builds; in dev
/// it honours `GRID_CONTROL_PLANE_URL` so you can point the app at staging — see
/// [AppEnvironment].
final gridApiUrlProvider =
    Provider<String>((ref) => AppEnvironment.controlPlaneUrl);
