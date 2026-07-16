import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_gateway_service.dart';
import '../../../infrastructure/cli/hermes_platform_policy.dart';
import '../../agent/logic/hermes_tool.dart';
import 'messaging_platform.dart';

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

/// What a platform is on this computer.
sealed class MessagingState {
  const MessagingState();
}

/// No bot connected — the screen asks for one.
class MessagingDisconnected extends MessagingState {
  const MessagingDisconnected();
}

/// Whether a connected bot is actually answering right now — the honest half,
/// read from Hermes's own gateway state, not guessed from a heartbeat. A bot
/// being set up and the bot *answering* are different things.
enum MessagingLink {
  /// The gateway loaded the credentials and the platform is connected — messages
  /// get answered.
  answering,

  /// The gateway is bringing the bot up (connecting, or retrying after a blip).
  connecting,

  /// The gateway is off, or up but the bot didn't connect — see
  /// [MessagingConnected.detail] for which.
  notAnswering,
}

/// A bot is connected (its credentials are set). [link] is the honest half:
/// connected and *answering* are different things, and a bot whose gateway is
/// down — or whose token another process is polling — answers nobody.
class MessagingConnected extends MessagingState {
  const MessagingConnected({
    required this.allowedUsers,
    required this.link,
    this.detail,
  });

  /// Who may message it. Never empty — the app won't connect a bot without one.
  final List<String> allowedUsers;
  final MessagingLink link;

  /// Why it isn't answering, when [link] is [MessagingLink.notAnswering] — the
  /// gateway's own reason (a bad token, another process on the same bot) or the
  /// gateway simply being off. Null otherwise.
  final String? detail;
}

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
      // Pin the read-and-answer limit before the gateway comes up, so the very
      // first message a remote user can send already runs without a terminal.
      await _restrict();
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
    try {
      // A bot connected before this limit existed is brought under it here, as
      // the gateway restarts to pick the change up.
      await _restrict();
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

  /// Hold this platform to read-and-answer in Hermes's config. Best-effort: a
  /// config the app can't write shouldn't block connecting the bot — but it's
  /// written before every (re)start, so the limit lands as soon as it can.
  Future<void> _restrict() async {
    final policy = ref.read(hermesPlatformPolicyProvider);
    if (policy == null) return;
    await policy.restrict(_platform.key);
  }

  static const _noAgent =
      "This computer isn't set up to answer chats yet. Open the account menu ▸ "
      'This computer to finish setting it up.';
}

/// Map the gateway's raw signals to the honest UI link. [gatewayAlive] is the
/// heartbeat — is the gateway process up at all; [state]/[error] are the live
/// platform status from the gateway's state file. Pure so the mapping is
/// unit-tested rather than guessed at in a widget.
({MessagingLink link, String? detail}) messagingLinkFrom({
  required bool gatewayAlive,
  required String state,
  String? error,
}) {
  if (!gatewayAlive) {
    return (
      link: MessagingLink.notAnswering,
      detail: "The gateway that answers messages isn't running.",
    );
  }
  return switch (state) {
    'connected' => (link: MessagingLink.answering, detail: null),
    'connecting' ||
    'retrying' => (link: MessagingLink.connecting, detail: null),
    'disconnected' || 'fatal' || 'paused' => (
      link: MessagingLink.notAnswering,
      detail: error ?? "The bot didn't connect.",
    ),
    // Gateway is up but has no entry for this platform yet — the credentials
    // haven't loaded (e.g. added but the gateway wasn't restarted to pick
    // them up).
    _ => (
      link: MessagingLink.notAnswering,
      detail:
          error ?? "The bot's credentials haven't loaded into the gateway yet.",
    ),
  };
}
