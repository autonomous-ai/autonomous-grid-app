import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_gateway_service.dart';
import '../../../infrastructure/cli/hermes_platform_policy.dart';
import '../../agents/logic/adapters/hermes_grid_link.dart';
import '../../agents/logic/adapters/hermes_tool.dart';
import '../../../shared/copy/setup_hints.dart';
import 'messaging_platform.dart';
import 'messaging_state.dart';

/// Said under a bot Hermes still runs. Moving it is the user's call, not
/// something done behind their back: it rewrites Hermes's settings and
/// restarts the program that also runs their scheduled tasks.
const String _kStillInHermes =
    'This bot still answers through the background program Grid used before '
    "— it won't ask you before acting, and its chats don't show up in Chat. "
    'To have Grid answer it instead, disconnect it and connect it again here.';

/// The gateway seam, or null when Hermes isn't on this computer.
final hermesGatewayServiceProvider = Provider<HermesGatewayService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesGatewayServiceImpl(path);
});

/// The seam onto Hermes's config that says what a platform's message may do on
/// this computer. Null when Hermes isn't on this computer.
final hermesPlatformPolicyProvider = Provider<HermesPlatformPolicy?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesPlatformPolicy();
});

/// A Telegram bot Hermes's gateway still runs, set up before Grid answered
/// Telegram itself.
///
/// Read so the screen never hides a computer that answers strangers, and so
/// the bot can be disconnected or restarted. Nothing connects a new bot this
/// way any more: Connect goes to Grid's own bot.
final hermesTelegramProvider =
    AsyncNotifierProvider<HermesTelegramController, MessagingState>(
      HermesTelegramController.new,
    );

class HermesTelegramController extends AsyncNotifier<MessagingState> {
  static const _platform = MessagingPlatform.telegram;

  @override
  Future<MessagingState> build() => _read();

  Future<MessagingState> _read() async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return const MessagingDisconnected();

    final env = await gateway.readEnv();
    // The bot token being set is what "connected" means — an empty one is a
    // computer with no bot at all.
    if ((env[_platform.credentials.first.key] ?? '').isEmpty) {
      return const MessagingDisconnected();
    }

    // Two signals: the heartbeat says whether the gateway process is alive at
    // all, and its state file says whether the platform itself connected. Only
    // both together is honestly "Answering".
    final alive = await gateway.running();
    final status = await gateway.readLink(_platform.key);
    final link = messagingLinkFrom(
      gatewayAlive: alive,
      state: status.state,
      error: status.error,
    );
    return MessagingConnected(
      allowedUsers: parseAllowedUsers(env[_platform.allowedUsersKey] ?? ''),
      link: link.link,
      detail: link.detail,
      host: MessagingHost.hermes,
      note: _kStillInHermes,
    );
  }

  /// Forget the bot, and stop the gateway answering as it.
  Future<String?> disconnect() async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return _noAgent;
    try {
      await gateway.removeEnv({
        for (final field in _platform.credentials) field.key,
        _platform.allowedUsersKey,
        _platform.homeChannelKey,
      });
      await gateway.restartGateway();
    } on HermesGatewayException catch (error) {
      return "Disconnected, but the gateway didn't restart: ${error.message}";
    } finally {
      state = AsyncData(await _read());
    }
    return null;
  }

  /// Start the thing that answers messages, then re-check — so the warning
  /// clears itself instead of leaving the user wondering whether it worked.
  Future<String?> start() async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return _noAgent;

    // A bot connected before the app pointed the assistant at a grid is brought
    // up to date here, as the gateway restarts to pick the changes up.
    final unpointed = await _pointAtGrid();
    if (unpointed != null) return unpointed;

    try {
      await _unpinToolsets();
      await gateway.startGateway();
    } on HermesGatewayException catch (error) {
      return "Couldn't start it: ${error.message}";
    }
    state = AsyncData(await _read());
    return null;
  }

  /// Make sure the assistant has a grid to answer with, and say what's missing
  /// when it can't have one. Shared with the scheduler — see
  /// [HermesGridLink.ensureModelForSelectedGrid].
  ///
  /// Not a nicety: the assistant keeps its own config, and until that names a
  /// grid it has no model to call — the bot would come up, show as
  /// "Answering", and fail on every message.
  Future<String?> _pointAtGrid() =>
      ref.read(hermesGridLinkProvider).ensureModelForSelectedGrid();

  /// Let the bot use whatever Hermes itself loads, dropping the read-and-answer
  /// pin an older build wrote. Best-effort: a config the app can't write
  /// shouldn't block restarting the bot — and it runs before every restart, so a
  /// still-pinned config repairs itself as soon as it can.
  Future<void> _unpinToolsets() async {
    final policy = ref.read(hermesPlatformPolicyProvider);
    if (policy == null) return;
    await policy.unpin(_platform.key);
  }

  static final _noAgent = notSetUpToMessage('answer chats');
}
