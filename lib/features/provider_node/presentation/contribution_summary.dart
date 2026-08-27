import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/serving_engines_provider.dart';
import 'engine_cost_chip.dart';

/// The one-line answer to the question this tab exists to answer: *what is this
/// computer giving the grid right now?*
///
/// Previously that took reading the whole page — the serving list showed each
/// engine but nothing stated the total, so an idle machine and a busy one looked
/// alike above the fold. This sits at the top of the page in both states.
///
/// It summarises only; every control still lives in the serving list below, so
/// there is exactly one place to stop an engine.
class ContributionSummary extends StatelessWidget {
  const ContributionSummary({
    super.key,
    required this.engines,
    required this.gridName,
    required this.starting,
  });

  final List<ServingEngine> engines;
  final String gridName;

  /// A join is in flight. Shown as its own state so the gap between pressing
  /// Start and the engine appearing doesn't read as "nothing is happening".
  final bool starting;

  /// Every distinct model this machine serves, across the union. Deduped: two
  /// engines may advertise the same name, and counting it twice would overstate
  /// what the grid actually gains.
  Set<String> get _models => {for (final engine in engines) ...engine.models};

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final live = engines.isNotEmpty;
    final count = _models.length;

    final headline = switch ((live, starting)) {
      (true, _) =>
        count == 1
            ? 'Sharing 1 model with $gridName'
            : 'Sharing $count models with $gridName',
      (false, true) => 'Starting an engine on $gridName…',
      (false, false) => 'This computer isn’t sharing anything yet',
    };

    final sub = live
        ? 'Anyone on this grid can use ${count == 1 ? 'it' : 'them'} right now.'
        : starting
        ? 'It will appear here as soon as it’s serving.'
        : 'Pick a way below and this computer starts answering for '
              '$gridName.';

    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: StatusDot(
              color: live ? AppPalette.online : AppPalette.offline,
              size: 8,
              pulsing: live,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (live) ...[
                  const SizedBox(height: 9),
                  _CostChips(engines: engines),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The distinct cost profiles in play, at most one chip each. A machine running
/// a local engine *and* a hosted one is spending both electricity and money, and
/// that's worth seeing without opening anything.
class _CostChips extends StatelessWidget {
  const _CostChips({required this.engines});

  final List<ServingEngine> engines;

  @override
  Widget build(BuildContext context) {
    final costs = {for (final engine in engines) costOfEngineKind(engine.kind)};
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        // Fixed order so the row doesn't reshuffle as engines come and go.
        for (final cost in EngineCost.values)
          if (costs.contains(cost)) EngineCostChip(cost: cost, compact: true),
      ],
    );
  }
}
