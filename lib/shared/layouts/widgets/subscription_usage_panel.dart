import 'package:flutter/material.dart';

import '../../../features/agents/logic/agent_catalog.dart';
import '../../../features/agents/logic/subscription_usage.dart';
import '../../theme/app_theme.dart';
import 'pill_panel_shell.dart';

/// What one account has spent, window by window — the panel behind the rail's
/// usage figures.
///
/// The rail prints the same numbers; this gives them the room to say which
/// window each belongs to, how full it is, and when it starts over. Same
/// furniture as the grid's own panels ([PillPanelSurface], [UsageTrack]), so
/// four popovers opening from one strip read as one family.
class SubscriptionUsagePanel extends StatelessWidget {
  const SubscriptionUsagePanel({super.key, required this.usage});

  final AgentUsage usage;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final windows = usage.windows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(agent: usage.agent, fetchedAt: usage.fetchedAt),
        if (windows.isEmpty) ...[
          const SizedBox(height: 10),
          Text(
            // The reading wrote this sentence, because the reading is what
            // knows whether signing in or trying again is the way out of it.
            usage.message ?? 'No limits to show',
            style: TextStyle(
              color: AppPalette.textFaint,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ] else
          for (final window in windows) ...[
            const SizedBox(height: 12),
            _WindowRow(window: window),
          ],
      ],
    );
  }
}

/// Whose account these figures belong to, and how fresh they are.
class _Header extends StatelessWidget {
  const _Header({required this.agent, required this.fetchedAt});

  final AgentTool agent;
  final DateTime? fetchedAt;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final at = fetchedAt;
    return Row(
      children: [
        // The assistant's own mark — the same asset its row in the agent picker
        // wears, so one account never looks like two things.
        Image.asset(agent.iconAsset, width: 14, height: 14),
        const SizedBox(width: 7),
        Text(
          agent.name,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 12.5,
            fontWeight: AppFont.semibold,
          ),
        ),
        const Spacer(),
        if (at != null)
          // Flexible, not bare: the account's name is the header's point and
          // must not be pushed out by the freshness note beside it, which is
          // the half that can afford to shorten.
          Flexible(
            child: Text(
              usageFreshnessLabel(at),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(color: AppPalette.textFaint, fontSize: 10.5),
            ),
          ),
      ],
    );
  }
}

/// One window: what it is called, how full it is, and when it comes back.
class _WindowRow extends StatelessWidget {
  const _WindowRow({required this.window});

  final AgentUsageWindow window;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final resets = usageResetLabel(window.resetsAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          window.label,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 11.5,
            fontWeight: AppFont.medium,
          ),
        ),
        const SizedBox(height: 6),
        UsageTrack(usedPercent: window.usedPercent),
        const SizedBox(height: 5),
        Row(
          children: [
            Text(
              '${window.usedPercent.round()}% used',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 11,
                fontFeatures: AppFont.tabularFigures,
              ),
            ),
            const Spacer(),
            // No reset time means no countdown — never "resets in 0m", which
            // would read as a measurement rather than as the silence it is.
            if (resets != null)
              Text(
                'Resets in $resets',
                style: TextStyle(color: AppPalette.textFaint, fontSize: 11),
              ),
          ],
        ),
      ],
    );
  }
}
