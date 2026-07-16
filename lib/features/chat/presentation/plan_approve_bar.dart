import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';

/// A slim bar above the composer when the agent has proposed a plan (Plan mode)
/// and is waiting on the user: read the plan above, then approve it to let the
/// agent carry it out, or dismiss it and keep chatting. Shown only while a plan
/// is pending and nothing is in flight, so it never lingers over a live reply or
/// an ordinary chat.
class PlanApproveBar extends ConsumerWidget {
  const PlanApproveBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // rebuild on theme flip — reads palette tokens
    final sessions = ref.watch(chatSessionsProvider);
    if (!sessions.awaitingPlan || sessions.sending) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(chatSessionsProvider.notifier);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      child: Row(
        children: [
          Icon(
            Icons.checklist_rounded,
            size: 17,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Review the plan above, then run it',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: controller.dismissPlan,
            child: const Text('Not now'),
          ),
          const SizedBox(width: 4),
          _RunButton(onRun: controller.approvePlan),
        ],
      ),
    );
  }
}

/// The primary action: approve the plan and let the agent run it. A soft
/// accent-tinted pill, matching the changes bar's "Undo all". Tapping it starts
/// the execute turn, which flips the bar off on its own (the plan is no longer
/// pending), so it needs no busy state of its own.
class _RunButton extends StatelessWidget {
  const _RunButton({required this.onRun});

  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads accent token
    return Material(
      color: AppPalette.accent.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: onRun,
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
                'Approve & run',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
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
