import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../messaging_controller.dart';
import '../messaging_platform.dart';
import 'telegram_bot_controller.dart';

/// Said under a bot that is still run by Hermes, set up before Grid could
/// answer Telegram itself. Moving it is the user's call, not something done
/// behind their back: it rewrites Hermes's settings and restarts the program
/// that also runs their scheduled tasks.
const String _kStillInHermes =
    'This bot still answers through the background program Grid used before '
    "— it won't ask you before acting, and its chats don't show up in Chat. "
    'To have Grid answer it instead, disconnect it and connect it again here.';

/// Telegram as the Messages screen sees it: the bot Grid runs itself, or —
/// until the user moves it — one Hermes still runs from before.
final telegramMessagingProvider =
    AsyncNotifierProvider<TelegramMessagingController, MessagingState>(
      TelegramMessagingController.new,
    );

class TelegramMessagingController extends AsyncNotifier<MessagingState>
    implements MessagingActions {
  static const _platform = MessagingPlatform.telegram;

  @override
  Future<MessagingState> build() async {
    final bot = ref.watch(telegramBotProvider);
    switch (bot) {
      case TelegramBotOn(:final config, :final link, :final detail):
        return MessagingConnected(
          allowedUsers: config.allowedUsers,
          link: link,
          detail: detail,
          handle: config.botName.isEmpty ? null : '@${config.botName}',
          host: MessagingHost.grid,
        );
      case TelegramBotLoading():
        // Grid hasn't read its saved bot yet — a moment at launch. Waiting
        // shows the spinner rather than flashing the connect form; this runs
        // again the moment the bot is read.
        return Completer<MessagingState>().future;
      case TelegramBotOff():
        return _hermesOrNothing();
    }
  }

  Future<MessagingState> _hermesOrNothing() async {
    final hermes = await ref.watch(messagingProvider(_platform).future);
    if (hermes is! MessagingConnected) {
      return const MessagingDisconnected(host: MessagingHost.grid);
    }
    return MessagingConnected(
      allowedUsers: hermes.allowedUsers,
      link: hermes.link,
      detail: hermes.detail,
      note: _kStillInHermes,
    );
  }

  bool get _inGrid => ref.read(telegramBotProvider) is TelegramBotOn;

  @override
  Future<String?> connect({
    required Map<String, String> credentials,
    required String userId,
  }) => ref
      .read(telegramBotProvider.notifier)
      .connect(
        token: credentials[_platform.credentials.first.key] ?? '',
        userId: userId,
      );

  @override
  Future<String?> disconnect() async {
    if (!_inGrid) {
      return ref.read(messagingProvider(_platform).notifier).disconnect();
    }
    await ref.read(telegramBotProvider.notifier).disconnect();
    return null;
  }

  @override
  Future<String?> start() async {
    if (!_inGrid) {
      return ref.read(messagingProvider(_platform).notifier).start();
    }
    await ref.read(telegramBotProvider.notifier).restart();
    return null;
  }
}
