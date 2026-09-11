import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'messaging_controller.dart';
import 'messaging_platform.dart';
import 'telegram/telegram_messaging_controller.dart';

export 'messaging_state.dart';

/// What one platform is on this computer, from whichever controller runs it.
///
/// An exhaustive switch rather than a flag on the platform, so the next
/// platform Grid learns to host has to say so here — a flag flipped without a
/// controller behind it would read another platform's state.
final messagingStateProvider =
    Provider.family<AsyncValue<MessagingState>, MessagingPlatform>(
      (ref, platform) => switch (platform) {
        MessagingPlatform.telegram => ref.watch(telegramMessagingProvider),
        MessagingPlatform.discord ||
        MessagingPlatform.slack => ref.watch(messagingProvider(platform)),
      },
    );

/// Connect, disconnect and restart for one platform — see [MessagingActions].
final messagingActionsProvider =
    Provider.family<MessagingActions, MessagingPlatform>(
      (ref, platform) => switch (platform) {
        MessagingPlatform.telegram => ref.watch(
          telegramMessagingProvider.notifier,
        ),
        MessagingPlatform.discord || MessagingPlatform.slack => ref.watch(
          messagingProvider(platform).notifier,
        ),
      },
    );
