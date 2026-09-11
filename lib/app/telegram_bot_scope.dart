import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/messaging/logic/telegram/telegram_bot_controller.dart';

/// Runs the Telegram bot Grid answers as, for the life of the app.
///
/// A widget rather than a call in `main()` because the bot is a provider, and
/// the `ProviderScope` it lives in only exists inside the tree. It draws
/// nothing — [child] is passed straight through — and it is the bot's one
/// listener: Riverpod pauses a provider nobody listens to, and a paused bot
/// never hears the permission requests it has to put to the phone.
///
/// Above the router for the Grid Panel's reason: a message from a phone
/// answers to the computer, not to whichever screen happens to be open.
class TelegramBotScope extends ConsumerStatefulWidget {
  const TelegramBotScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TelegramBotScope> createState() => _TelegramBotScopeState();
}

class _TelegramBotScopeState extends ConsumerState<TelegramBotScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: nobody is waiting on the bot to draw the window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(telegramBotProvider.notifier).resume());
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(telegramBotProvider, (_, _) {});
    return widget.child;
  }
}
