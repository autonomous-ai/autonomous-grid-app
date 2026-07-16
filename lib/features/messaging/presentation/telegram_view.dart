import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/section_scaffold.dart';
// For telegram_connected_panel.dart, a part of this library.
import '../../../shared/widgets/toast.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/telegram_controller.dart';

part 'telegram_connect_form.dart';
part 'telegram_connected_panel.dart';

/// Talk to this computer from Telegram.
///
/// The bot runs *here*: your message goes to the assistant on this machine, which
/// answers with the same model as the Chat tab and can read the same files. That
/// also means the two things this screen never hides — only the people you list
/// may message it, and it goes quiet when this computer does.
class TelegramView extends ConsumerWidget {
  const TelegramView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(hermesInstalledProvider)) return const _NoAgent();

    final telegram = ref.watch(telegramProvider);
    return SectionScaffold(
      title: 'Telegram',
      subtitle:
          'Message the assistant from your phone. It answers from this '
          'computer, with your own model — nothing is sent to anyone else.',
      child: switch (telegram) {
        AsyncData(
          value: TelegramConnected(
            :final allowedUsers,
            :final link,
            :final detail,
          ),
        ) =>
          TelegramConnectedPanel(
            allowedUsers: allowedUsers,
            link: link,
            detail: detail,
          ),
        AsyncData() => const TelegramConnectForm(),
        AsyncError(:final error) => Text(
          "Couldn't read your Telegram setup: $error",
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

/// Nothing on this computer can answer a message yet.
class _NoAgent extends ConsumerWidget {
  const _NoAgent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Telegram',
      subtitle: 'Message the assistant from your phone.',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "This computer isn't set up to answer chats yet, so there's "
              'nothing for a bot to answer with.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => ref
                  .read(shellSectionProvider.notifier)
                  .select(ShellSection.engines),
              child: const Text('Set up this computer'),
            ),
          ],
        ),
      ),
    );
  }
}
