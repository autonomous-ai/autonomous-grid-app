import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/copy/plural.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/composer_notice_bar.dart';
import '../logic/chat_sessions_controller.dart';

/// A slim bar above the composer when the assistant stopped for want of room
/// rather than because it was done: it used every tool call one turn allows and
/// was made to summarise mid-plan.
///
/// It exists because the alternative is silence. The assistant's runtime reports
/// a turn it cut off exactly like a finished one, so a five-step plan abandoned
/// at three arrived looking like completed work — and "why does it keep stopping
/// halfway?" had no answer anywhere in the app.
///
/// Since issue #28 the app carries on by itself first (up to [kCarryOnTurns]),
/// so by the time this bar appears the work has usually been through several
/// turns already — and the bar says so rather than reading like the first stop.
class OutOfStepsBar extends ConsumerWidget {
  const OutOfStepsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Selected down to what the bar draws, so a streamed token doesn't rebuild a
    // bar that sits over the composer for the whole conversation.
    final (show, carriedOn) = ref.watch(
      chatSessionsProvider.select(
        (s) => (s.outOfSteps && !s.sending, s.carriedOnHere),
      ),
    );
    if (!show) return const SizedBox.shrink();
    final controller = ref.read(chatSessionsProvider.notifier);
    return ComposerNoticeBar(
      icon: Icons.hourglass_bottom_rounded,
      // No jargon: the user doesn't have "tool-calling iterations", they have an
      // assistant that stopped with work left (§5). And when the app has already
      // spent turns of its own on this, it says how many — those turns cost the
      // user's grid, and they happened while nobody was watching.
      label: carriedOn == 0
          ? 'The assistant hit its limit for one reply and stopped mid-task'
          : 'The assistant carried on $carriedOn more '
                '${plural(carriedOn, 'time')} and still has not finished',
      onDismiss: controller.dismissOutOfSteps,
      actions: [_CarryOnButton(onTap: controller.continueTurn)],
    );
  }
}

/// The primary action: a fresh turn, which is a fresh budget. Tapping it starts
/// that turn, which clears the flag on its own, so it needs no busy state.
class _CarryOnButton extends StatelessWidget {
  const _CarryOnButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads accent token
    return Material(
      color: AppPalette.accent.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_arrow_rounded,
                size: 16,
                color: AppPalette.accent,
              ),
              const SizedBox(width: 8),
              Text(
                'Carry on',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFont.medium,
                  color: AppPalette.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
