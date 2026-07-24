import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/provider_node/logic/self_plan_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/chatgpt_logo.dart';
import 'top_bar_pill.dart';

/// The plan the user joined this grid with — "Pro plan", "Plus plan" — shown in
/// the top bar when this machine is hosting with a ChatGPT/Codex subscription
/// seat (ADR 0015). It answers "what am I contributing, and at what tier?" the
/// moment you look up, rather than only on the grid page's node list.
///
/// Carries the OpenAI mark so the tier reads as a *subscription*, not a generic
/// badge, and picks up the accent tint the per-node plan badge already uses so
/// the two read as the same thing in two places.
///
/// Stays fully unmounted — pill and all — when this machine isn't hosting, or
/// hosts with hardware rather than a subscription, so the bar never shows a bare
/// capsule. See [selfPlanLabelProvider].
class PlanTypePill extends ConsumerWidget {
  const PlanTypePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final plan = ref.watch(selfPlanLabelProvider);
    if (plan == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        label: 'Your subscription: $plan',
        container: true,
        child: TopBarPill(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChatGptLogo(size: 13, color: AppPalette.accent),
              const SizedBox(width: 7),
              Text(
                plan,
                style: TextStyle(
                  fontSize: 12.5,
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
