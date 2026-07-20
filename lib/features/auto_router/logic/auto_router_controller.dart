import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import 'auto_router_models.dart';

/// Most advisors the chain accepts, matching the CLI's `MAX_ADVISORS`. The
/// picker caps at this so a too-long chain is refused in the UI, not by a 400.
const int kMaxAdvisors = 3;

/// A failure worth showing the user, already humanized. Thrown by the controller
/// so the card's error branch prints one plain line instead of raw CLI stderr.
class AutoRouterException implements Exception {
  const AutoRouterException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Auto-routing config for the active grid — `grid router status/enable/disable/
/// set-advisors`, all account-level owner commands (ADR 0013). Reloads when the
/// selected grid changes. Only rendered for a grid the viewer owns, so a
/// not-owner reply is an error path, not the normal case.
final autoRouterControllerProvider =
    AsyncNotifierProvider<AutoRouterController, AutoRouterConfig>(
      AutoRouterController.new,
    );

class AutoRouterController extends AsyncNotifier<AutoRouterConfig> {
  /// Grids this session already ran the owner auto-enable pass for, so the
  /// post-frame trigger from the card is idempotent per grid (the notifier
  /// instance outlives a grid switch, so a single bool wouldn't reset).
  final Set<String> _autoEnabledGrids = {};

  @override
  Future<AutoRouterConfig> build() async {
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) {
      throw const AutoRouterException('Select a grid first.');
    }
    return _status(network.networkId);
  }

  /// Turn routing on the first time an owner opens a grid they've never
  /// configured, so `auto` works out of the box without a manual toggle.
  ///
  /// A no-op when the viewer isn't the owner, while the status is still
  /// loading/errored, once this grid was already attempted this session, or when
  /// advisors already exist — routing is on, or the owner deliberately turned it
  /// off (advisors persist through `disable`), and either way their state is
  /// respected, never overridden. Scheduled post-frame by the owner-only card so
  /// it never mutates during build; the per-grid guard makes repeat calls cheap.
  Future<void> autoEnableForOwner() async {
    final network = ref.read(selectedNetworkProvider);
    if (network == null || !network.isOwner) return;
    final config = state.asData?.value;
    if (config == null) return; // still loading — the card retries next build
    if (!_autoEnabledGrids.add(network.networkId)) return; // once per grid
    if (config.enabled || config.hasAdvisors) return;
    await enableWithDefaultAdvisor();
  }

  /// Turn auto-routing on or off for the active grid, then reload the config.
  ///
  /// The control plane rejects `enable` with no advisor configured ("Configure
  /// an advisor first"), so callers must only enable once the chain is set — the
  /// card routes a first-time enable through [enableWithAdvisors] instead.
  Future<void> setEnabled(bool enabled) =>
      _mutate(['router', enabled ? 'enable' : 'disable']);

  /// Set the advisor chain, then enable — the order the control plane requires
  /// (an advisor must exist before `enable`). One guarded sequence so the card
  /// reflects the final state, or the first failure, and never a half-applied one.
  Future<void> enableWithAdvisors(List<String> tokens) {
    if (tokens.isEmpty) return Future.value();
    return _mutateMany([
      ['router', 'set-advisors', ...tokens],
      ['router', 'enable'],
    ]);
  }

  /// Turn routing on with a single switch: when the grid has no advisor yet,
  /// configure the catalog's default one automatically, then enable. This keeps
  /// the deciding-AI choice off the main flow — the owner enables routing over
  /// their running models without ever picking a cloud advisor (that stays an
  /// advanced step). A missing/empty catalog surfaces as a clean error, not a
  /// silent no-op.
  Future<void> enableWithDefaultAdvisor() async {
    final AdvisorCatalog catalog;
    try {
      catalog = await ref.read(advisorCatalogProvider.future);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      return;
    }
    final token = catalog.defaultToken;
    if (token == null) {
      state = AsyncError(
        const AutoRouterException(
          'No routing advisor is available right now — try again later.',
        ),
        StackTrace.current,
      );
      return;
    }
    await enableWithAdvisors([token]);
  }

  /// Replace the advisor chain (1–[kMaxAdvisors] `provider[:model]` tokens, in
  /// priority order), then reload. An empty list is a no-op — the CLI requires
  /// at least one advisor, so clearing the chain is `disable`, not an empty set.
  Future<void> setAdvisors(List<String> tokens) {
    if (tokens.isEmpty) return Future.value();
    return _mutate(['router', 'set-advisors', ...tokens]);
  }

  Future<void> _mutate(List<String> command) => _mutateMany([command]);

  /// Run one or more mutations for the active grid in order, then re-read status
  /// so the card reflects the server's own view (not an optimistic guess). One
  /// `guard` wraps the whole sequence, so a mid-sequence failure surfaces and no
  /// later step runs. The card holds its own busy flag around the await.
  Future<void> _mutateMany(List<List<String>> commands) async {
    final network = ref.read(selectedNetworkProvider);
    if (network == null) return;
    state = await AsyncValue.guard(() async {
      for (final command in commands) {
        _ensureOk(await _run([...command, '--grid', network.networkId]));
      }
      return _status(network.networkId);
    });
  }

  Future<AutoRouterConfig> _status(String gridId) async {
    final result = await _run(['router', 'status', '--grid', gridId]);
    return AutoRouterConfig.fromJson(_decodeObject(result));
  }

  Future<CliResult> _run(List<String> args) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      throw const AutoRouterException("The grid tool isn't available.");
    }
    // `--json` makes the router commands print a machine-readable body to stdout
    // — the one place we parse stdout rather than reading `~/.grid`, since the
    // config lives on the control plane, not on disk.
    return service.run([...args, '--json']);
  }

  /// Decode a `--json` reply to a JSON object, mapping any failure to a
  /// humanized [AutoRouterException].
  Map<String, dynamic> _decodeObject(CliResult result) {
    _ensureOk(result);
    try {
      final decoded = jsonDecode(result.stdout.trim());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Fall through to the generic message below.
    }
    throw const AutoRouterException('The grid returned an unexpected reply.');
  }

  void _ensureOk(CliResult result) {
    if (result.ok) return;
    throw AutoRouterException(_friendly(result));
  }

  static String _friendly(CliResult result) {
    if (result.sessionExpired) {
      return 'Your grid session expired — sign in again.';
    }
    final message = result.errorMessage.trim().toLowerCase();
    if (message.contains('owner') ||
        message.contains('forbidden') ||
        message.contains('not allowed')) {
      return 'Only the grid owner can change auto-routing.';
    }
    final raw = result.errorMessage.trim();
    if (raw.isEmpty) return "Couldn't reach the grid — try again.";
    return raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
  }
}

/// The platform advisor catalog (`grid router models`) — account-level, needs no
/// grid. Feeds the advisor picker so the chain is chosen by name.
final advisorCatalogProvider = FutureProvider<AdvisorCatalog>((ref) async {
  final service = ref.read(gridCliServiceProvider);
  if (service == null) {
    throw const AutoRouterException("The grid tool isn't available.");
  }
  final result = await service.run(['router', 'models', '--json']);
  if (!result.ok) {
    throw AutoRouterException(AutoRouterController._friendly(result));
  }
  try {
    final decoded = jsonDecode(result.stdout.trim());
    if (decoded is Map) {
      return AdvisorCatalog.fromJson(Map<String, dynamic>.from(decoded));
    }
  } on FormatException {
    // Fall through.
  }
  throw const AutoRouterException('The grid returned an unexpected reply.');
});
