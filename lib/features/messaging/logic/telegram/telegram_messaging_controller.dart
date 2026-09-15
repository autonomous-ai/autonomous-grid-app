import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../hermes_telegram_controller.dart';
import '../messaging_platform.dart';
import '../messaging_state.dart';
import 'telegram_bot_controller.dart';

/// Telegram as the Messages screen sees it: the bot Grid runs itself, or —
/// until the user moves it — one Hermes still runs from before.
final telegramMessagingProvider =
    AsyncNotifierProvider<TelegramMessagingController, MessagingState>(
      TelegramMessagingController.new,
    );

/// What the Messages screen does to the bot. Each action returns null on
/// success, else the line to show.
class TelegramMessagingController extends AsyncNotifier<MessagingState> {
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
        return ref.watch(hermesTelegramProvider.future);
    }
  }

  bool get _inGrid => ref.read(telegramBotProvider) is TelegramBotOn;

  /// [credentials] maps the platform's [CredentialField.key]s to what was
  /// pasted; [userId] is the one person allowed to message the bot to begin
  /// with — without it the bot would answer anyone who found it.
  Future<String?> connect({
    required Map<String, String> credentials,
    required String userId,
  }) => ref
      .read(telegramBotProvider.notifier)
      .connect(
        token:
            credentials[MessagingPlatform.telegram.credentials.first.key] ??
            '',
        userId: userId,
      );

  /// Forget the bot, and stop answering as it.
  Future<String?> disconnect() async {
    if (!_inGrid) return ref.read(hermesTelegramProvider.notifier).disconnect();
    await ref.read(telegramBotProvider.notifier).disconnect();
    return null;
  }

  /// Start answering again — the "Turn it on" button.
  Future<String?> start() async {
    if (!_inGrid) return ref.read(hermesTelegramProvider.notifier).start();
    await ref.read(telegramBotProvider.notifier).restart();
    return null;
  }
}
