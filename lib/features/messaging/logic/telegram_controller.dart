import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_gateway_service.dart';
import '../../agent/logic/hermes_tool.dart';

/// The gateway seam, or null when there's no agent on this computer — nothing to
/// answer a message with, so the screen says that instead of failing later.
final hermesGatewayServiceProvider = Provider<HermesGatewayService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesGatewayServiceImpl(path);
});

/// What Telegram is on this computer.
sealed class TelegramState {
  const TelegramState();
}

/// No bot connected — the screen asks for one.
class TelegramDisconnected extends TelegramState {
  const TelegramDisconnected();
}

/// A bot is connected. [running] is the honest half: connected and *listening*
/// are different things, and a bot whose gateway is down answers nobody.
class TelegramConnected extends TelegramState {
  const TelegramConnected({required this.allowedUsers, required this.running});

  /// Who may message it. Never empty — the app won't connect a bot without one.
  final List<String> allowedUsers;
  final bool running;
}

/// Chatting with this computer from Telegram: connect a bot, say who may use it,
/// and keep the gateway that answers them running.
final telegramProvider =
    AsyncNotifierProvider<TelegramController, TelegramState>(
      TelegramController.new,
    );

class TelegramController extends AsyncNotifier<TelegramState> {
  @override
  Future<TelegramState> build() => _read();

  Future<TelegramState> _read() async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return const TelegramDisconnected();

    final setup = await gateway.readTelegram();
    if (setup.token.isEmpty) return const TelegramDisconnected();
    return TelegramConnected(
      allowedUsers: setup.allowedUsers,
      running: await gateway.running(),
    );
  }

  /// Connect the bot and start answering. Returns null on success, else a line
  /// to show. [userId] is the one person allowed to message it to begin with —
  /// without it the bot would answer anyone who found it.
  Future<String?> connect({
    required String token,
    required String userId,
  }) async {
    final gateway = ref.read(hermesGatewayServiceProvider);
    if (gateway == null) return _noAgent;

    final invalid = validateBotToken(token) ?? validateTelegramId(userId);
    if (invalid != null) return invalid;

    state = const AsyncLoading();
    try {
      await gateway.connectTelegram(
        token: token.trim(),
        allowedUsers: [userId.trim()],
        // A task's result goes to the person who set this up — their own chat
        // with the bot, which on Telegram is their user id.
        homeChannel: userId.trim(),
      );
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
      await gateway.disconnectTelegram();
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
      await gateway.startGateway();
    } on HermesGatewayException catch (error) {
      return "Couldn't start it: ${error.message}";
    }
    state = AsyncData(await _read());
    return null;
  }

  static const _noAgent =
      "This computer isn't set up to answer chats yet. Open the account menu ▸ "
      'This computer to finish setting it up.';
}

/// The token @BotFather hands out looks like `8123456789:AAF…`. Checking the
/// shape here turns "the bot never answers" into an error the user can fix.
String? validateBotToken(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return 'Paste the token BotFather gave you.';
  if (!RegExp(r'^\d{6,}:[A-Za-z0-9_-]{20,}$').hasMatch(trimmed)) {
    return "That doesn't look like a bot token — it's a long line like "
        '8123456789:AAF… from @BotFather.';
  }
  return null;
}

/// A Telegram user id is a number (@userinfobot tells you yours).
String? validateTelegramId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return 'Add your Telegram id, or the bot would answer anyone who finds it.';
  }
  if (!RegExp(r'^\d{5,}$').hasMatch(trimmed)) {
    return 'A Telegram id is a number — message @userinfobot to get yours.';
  }
  return null;
}
