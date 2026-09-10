import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/subscription_model.dart';
import '../../../features/agents/logic/agent_catalog.dart';
import '../../../features/agents/logic/subscription_usage.dart';
import '../../../features/agents/logic/subscription_usage_provider.dart';
import '../../theme/app_theme.dart';
import 'grid_power_readout.dart' show RailStat;
import 'grid_target_menu.dart';
import 'rail_popover.dart';
import 'subscription_usage_panel.dart';

/// The status rail while the open chat answers **off the grid** — on the
/// account the assistant is signed in with.
///
/// The rail's other face reports the grid: its memory, its machines, what it
/// has answered. None of that is paying for this chat, so none of it is
/// reported here. What replaces it is the only thing that *is* being spent —
/// how much of [agent]'s own rate limits are gone, and when they come back.
///
/// The left end stays what it always was: the target, and the menu that changes
/// it ([GridTargetMenu]). The figures follow it there rather than sitting at
/// the far end of the rail: the grid's face reads from both ends because it has
/// two clusters saying different things (what the grid *is*, what it is *made
/// of*), and this one has a single statement to make — how much of one account
/// is left. Split across a 1400px rail, that statement is read in two glances
/// instead of one.
class SubscriptionRailRow extends ConsumerWidget {
  const SubscriptionRailRow({super.key, required this.agent});

  /// The assistant whose account answers — never Hermes, which has none (see
  /// [subscriptionUsageAgentProvider]).
  final AgentTool agent;

  /// Narrower than a panel listing machines: this one holds two windows, each a
  /// label over a bar, and the longest line in it is "Resets in 3d 14h".
  static const double _panelWidth = 246;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final usage = ref.watch(subscriptionUsageProvider(agent));
    return Row(
      children: [
        GridTargetMenu(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // No live dot. It reports a grid being up, and no grid is
              // answering this chat — a green dot here would be a claim about
              // something that has nothing to do with the reply.
              Icon(LucideIcons.zap300, size: 13, color: AppPalette.textFaint),
              const SizedBox(width: 7),
              Text(
                kSubscriptionModelLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFont.medium,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              // Whose account, in the same breath: two assistants can be signed
              // in on one computer, and "your subscription" alone does not say
              // which of them the figures beside it belong to.
              Text(
                agent.name,
                style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
              ),
            ],
          ),
        ),
        // Read at the moment it is drawn, not at the moment it was fetched: a
        // countdown is a fact about now.
        //
        // The figures and the panel behind them are one target: the rail has
        // room for two percentages, and everything else the reading knows —
        // which window, how full, when it comes back, how old the reading is —
        // lives a hover away rather than nowhere. Wrapped as a group, not per
        // figure, because the panel says the same thing whichever of the two
        // the pointer landed on.
        if (usage.value case final reading?) ...[
          const SizedBox(width: 16),
          if (reading.windows.isNotEmpty)
            RailPopover(
              width: _panelWidth,
              panel: () => SubscriptionUsagePanel(usage: reading),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _figures(reading),
              ),
            )
          // Nothing to expand: the sentence *is* the whole reading, and a panel
          // that opened to repeat it would be a hover target rewarding nobody.
          // Flexible here and not inside the popover's row — that one is
          // `mainAxisSize.min` and unbounded, where a Flexible is a layout
          // error rather than an ellipsis.
          else if (reading.message case final message?)
            Flexible(child: _Note(message)),
        ],
      ],
    );
  }

  /// The windows, with the gap between them rather than after the last, so the
  /// row ends on the last thing it has to say instead of on empty space.
  ///
  /// Only ever called with windows in hand — the reading with none is a
  /// sentence, and it is drawn above rather than here.
  List<Widget> _figures(AgentUsage usage) => [
    for (final (index, window) in usage.windows.indexed) ...[
      if (index > 0) const SizedBox(width: 16),
      _Window(window: window),
    ],
  ];
}

/// One window: what it is called, how much is gone, and how long until it comes
/// back.
class _Window extends StatelessWidget {
  const _Window({required this.window});

  final AgentUsageWindow window;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final resets = usageResetLabel(window.resetsAt);
    return Tooltip(
      message: resets == null
          ? '${window.label}: ${window.usedPercent.round()}% of the limit used'
          : '${window.label}: ${window.usedPercent.round()}% used, '
                'resets in $resets',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            window.label,
            style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
          ),
          const SizedBox(width: 6),
          RailStat(
            value: '${window.usedPercent.round()}%',
            // "used" rather than nothing: a bare percentage beside a countdown
            // reads as how much is *left* about as often as how much is gone.
            unit: resets == null ? 'used' : 'used · $resets',
          ),
        ],
      ),
    );
  }
}

/// What the rail says when there are no figures to say.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
    );
  }
}
