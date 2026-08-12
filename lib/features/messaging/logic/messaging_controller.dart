import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_gateway_service.dart';
import '../../../infrastructure/cli/hermes_platform_policy.dart';
import '../../agents/logic/adapters/hermes_grid_link.dart';
import '../../agents/logic/adapters/hermes_tool.dart';
import '../../../shared/copy/setup_hints.dart';
import 'messaging_platform.dart';
import 'messaging_state.dart';

// The state this controller exposes lives next door, but every caller reads it
// through the controller — so it comes along with this import.
export 'messaging_state.dart';

/// The gateway seam, or null when there's no agent on this computer — nothing to
/// answer a message with, so the screen says that instead of failing later.
final hermesGatewayServiceProvider = Provider<HermesGatewayService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesGatewayServiceImpl(path);
});

/// The seam onto Hermes's config that says what a platform's message may do on
/// this computer. Null when there's no agent to run one.
final hermesPlatformPolicyProvider = Provider<HermesPlatformPolicy?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesPlatformPolicy();
});

/// Chatting with this computer from a platform: connect a bot, say who may use
/// it, and keep the gateway that answers them running. One controller per
/// platform, so Telegram, Discord and Slack each hold their own state.
final messagingProvider =
    AsyncNotifierProvider.family<
      MessagingController,
      MessagingState,
      MessagingPlatform
    >(MessagingController.new);

class MessagingController extends AsyncNotifier<MessagingState> {
  MessagingController(this._platform);

  /// The platform this controller answers for — Riverpod hands it to the factory
  /// when the family resolves `messagingProvider(platform)`.
  final MessagingPlatform _platform;

  @override
  Future<MessagingState> build() => _read();

  Future<MessagingState> _read() async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return const MessagingDisconnected();

    final env = await gateway.readEnv();
    // The primary credential (the bot token) being set is what "connected"
    // means — an empty one is a computer with no bot at all.
    if ((env[_platform.credentials.first.envKey] ?? '').isEmpty) {
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
    );
  }

  /// Connect the bot and start answering. Returns null on success, else a line
  /// to show. [credentials] maps each of the platform's `.env` keys to its
  /// pasted value; [userId] is the one person allowed to message it to begin
  /// with — without it the bot would answer anyone who found it.
  Future<String?> connect({
    required Map<String, String> credentials,
    required String userId,
  }) async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return _noAgent;

    final invalid = _firstInvalid(credentials, userId);
    if (invalid != null) return invalid;

    // Before anything is written: an assistant with no grid to answer with would
    // leave a bot that connects and then says nothing — see [_pointAtGrid].
    final unpointed = await _pointAtGrid();
    if (unpointed != null) return unpointed;

    final trimmedUser = userId.trim();
    state = const AsyncLoading();
    try {
      await gateway.writeEnv({
        for (final field in _platform.credentials)
          field.envKey: (credentials[field.envKey] ?? '').trim(),
        _platform.allowedUsersKey: trimmedUser,
        // A task's result goes to the person who set this up — on Telegram their
        // own chat is their user id; other platforms deliver to a channel we
        // don't collect yet.
        if (_platform.homeChannelKey != null && _platform.homeChannelIsUserId)
          _platform.homeChannelKey!: trimmedUser,
      }, addedBy: 'lets you chat with this computer from ${_platform.label}');
      // Clear any old read-and-answer pin before the gateway comes up, so the
      // very first message already reaches the tools the in-app chat has.
      await _unpinToolsets();
      await gateway.startGateway();
    } on HermesGatewayException catch (error) {
      state = AsyncData(await _read());
      return "Couldn't connect the bot: ${error.message}";
    }
    state = AsyncData(await _read());
    return null;
  }

  /// Forget the bot, and stop the gateway answering as it.
  Future<String?> disconnect() async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return _noAgent;
    try {
      await gateway.removeEnv({
        for (final field in _platform.credentials) field.envKey,
        _platform.allowedUsersKey,
        if (_platform.homeChannelKey != null) _platform.homeChannelKey!,
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

  /// The first credential or id that's the wrong shape, or null when all are
  /// fine — caught here so "the bot never answers" becomes a fixable error.
  String? _firstInvalid(Map<String, String> credentials, String userId) {
    for (final field in _platform.credentials) {
      final error = field.validate?.call(credentials[field.envKey] ?? '');
      if (error != null) return error;
    }
    return _platform.userIdValidate(userId);
  }

  /// Make sure the assistant has a grid to answer with before a bot goes live,
  /// and say what's missing when it can't have one. Shared with the scheduler —
  /// see [HermesGridLink.ensureModelForSelectedGrid].
  ///
  /// Not a nicety: the assistant keeps its own config, and until that names a
  /// grid it has no model to call. A bot connected before the user ever chatted
  /// in the app would come up, show as "Answering", and fail on every message —
  /// so the grid is written here rather than only on the way to a chat message.
  Future<String?> _pointAtGrid() =>
      ref.read(hermesGridLinkProvider).ensureModelForSelectedGrid();

  /// Let this platform use whatever Hermes itself loads, dropping the
  /// read-and-answer pin an older build wrote. Best-effort: a config the app
  /// can't write shouldn't block connecting the bot — and it runs before every
  /// (re)start, so a still-pinned config repairs itself as soon as it can.
  Future<void> _unpinToolsets() async {
    final policy = ref.read(hermesPlatformPolicyProvider);
    if (policy == null) return;
    await policy.unpin(_platform.key);
  }

  static final _noAgent = notSetUpToMessage('answer chats');
}
