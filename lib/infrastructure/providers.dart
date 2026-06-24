import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cli/command_log.dart';
import 'cli/grid_cli_service.dart';
import 'cli/grid_cli_service_impl.dart';
import 'cli/grid_resolver.dart';
import 'cli/logging_grid_cli_service.dart';
import 'state/grid_home_store.dart';

/// Locates the `grid` binary (sidecar → GRID_BIN → PATH). A user-configured
/// path from settings gets threaded in here later.
final gridResolverProvider = Provider<GridResolver>((ref) => GridResolver());

/// Absolute path to `grid`, or null when it cannot be found.
final gridPathProvider =
    Provider<String?>((ref) => ref.watch(gridResolverProvider).resolve());

/// The CLI seam. Null when `grid` is absent — preflight gates the rest of the
/// app on this being non-null. Override with [FakeGridCliService] in dev/test.
/// Wrapped in [LoggingGridCliService] so every command shows up in the Debug tab.
final gridCliServiceProvider = Provider<GridCliService?>((ref) {
  final path = ref.watch(gridPathProvider);
  if (path == null) return null;
  final recorder = ref.read(commandLogProvider.notifier);
  return LoggingGridCliService(GridCliServiceImpl(path), recorder);
});

/// Reads state from `~/.grid` (nguồn 1). Read-only; mutations go through the CLI.
final gridHomeStoreProvider =
    Provider<GridHomeStore>((ref) => const GridHomeStore());

/// Control-plane URL passed to `grid auth login --api-url`. Defaults to prod;
/// override for staging/local.
final gridApiUrlProvider =
    Provider<String>((ref) => 'https://api-grid.autonomous.ai/');
