import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/remote_reach.dart';

/// Says whether this computer answers messages from outside it.
///
/// The Messages screen holds the setup, and it is developer-gated; this is the
/// one fact from it that everyone should be able to see without going looking —
/// a machine that will answer a stranger on Telegram while nobody is sitting at
/// it. Where that setup lives is a question; whether it is *on* is not.
///
/// Nothing at all when no bot is connected, which is the usual case.
class RemoteReachRow extends ConsumerWidget {
  const RemoteReachRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final reach = ref.watch(remoteReachProvider);
    final label = remoteReachLabel(reach);
    if (label == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          StatusDot(
            // Green only for a bot that is actually answering — connected but
            // silent is the state most worth telling apart.
            color: reach.answering ? AppPalette.online : AppPalette.textFaint,
            size: 8,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
