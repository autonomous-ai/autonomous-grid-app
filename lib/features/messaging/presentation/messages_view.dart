import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
// For platform_connected_panel.dart, a part of this library.
import '../../../shared/widgets/toast.dart';
import '../logic/messaging_platform.dart';
import '../logic/messaging_state.dart';
import '../logic/telegram/telegram_messaging_controller.dart';

part 'platform_connect_form.dart';
part 'platform_connected_panel.dart';

/// Talk to this computer from Telegram.
///
/// The bot runs *here*: Grid itself answers it, with the assistant and model the
/// Chat tab uses, and each conversation lands in Chat. Two things this screen
/// never hides — only the people you list may message it, and it goes quiet
/// when Grid or this computer does.
class MessagesView extends StatelessWidget {
  const MessagesView({super.key});

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return const SectionScaffold(
      title: 'Messages',
      subtitle:
          'Message the assistant from Telegram on your phone. It answers from '
          'this computer, with the assistant and model you use in Chat.',
      child: _TelegramPane(),
    );
  }
}

/// The connect form or the connected panel — whichever the bot's live state
/// calls for.
class _TelegramPane extends ConsumerWidget {
  const _TelegramPane();

  static const _platform = MessagingPlatform.telegram;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(telegramMessagingProvider)) {
      AsyncData(value: final MessagingConnected connected) =>
        PlatformConnectedPanel(platform: _platform, connected: connected),
      AsyncData() => const PlatformConnectForm(platform: _platform),
      AsyncError(:final error) => Text(
        "Couldn't read your ${_platform.label} setup: $error",
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
    };
  }
}
