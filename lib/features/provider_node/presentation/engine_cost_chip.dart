import 'package:flutter/material.dart';

import '../../../infrastructure/state/models/engine_run.dart';
import '../../../shared/theme/app_theme.dart';

/// What running an engine costs the person who shares it. The two built-in paths
/// differ in a way the old UI only stated in prose at the foot of a block, where
/// it was easy to miss: a local engine spends *this machine* (power, GPU, disk),
/// while a hosted one spends *the user's own vendor account* per request. Getting
/// that wrong is expensive in real money, so it earns a chip at the point of
/// decision rather than a sentence below the fold.
enum EngineCost {
  /// Runs on this computer — no per-request bill.
  free,

  /// Billed to the user's own API key / subscription with the vendor.
  metered,
}

/// The cost of an engine of [kind]. Local and external engines both run on
/// hardware the user already pays for (their own machine, or a server they
/// chose), so neither bills per request; only a hosted API engine does.
EngineCost costOfEngineKind(EngineKind kind) => switch (kind) {
  EngineKind.local || EngineKind.external => EngineCost.free,
  EngineKind.api => EngineCost.metered,
};

/// A small pill naming an engine's [cost]. Deliberately quiet — it sits beside a
/// model name and must not out-shout it — but colour-coded so the distinction
/// survives a glance: indigo (the app's accent, meaning "nothing to worry about")
/// for free, the brand gold for metered, which is also the app's "attention, not
/// error" hue.
///
/// The label is never bare currency talk ("Paid"): a metered engine isn't Grid
/// billing anyone, it's the user's own account being spent, and the wording says
/// so.
class EngineCostChip extends StatelessWidget {
  const EngineCostChip({super.key, required this.cost, this.compact = false});

  final EngineCost cost;

  /// Drops the label to its shortest form for dense rows (the serving list),
  /// where the engine's own title already carries the context.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens from a const-constructible widget — without this it
    // keeps the palette it was first built with across a theme flip.
    // See AppTheme.watch.
    AppTheme.watch(context);
    final theme = Theme.of(context);

    // The gold is a brighter hue than the indigo, so an identical border alpha
    // reads noticeably louder on it (1.78:1 vs 1.54:1 against a dark card) — the
    // metered chip was out-shouting the block title beside it. Trimming only the
    // gold's border evens the two out; both chips state a fact, and neither is a
    // warning.
    final (color, label, icon, borderAlpha) = switch (cost) {
      EngineCost.free => (
        AppPalette.accentOnSurface,
        compact ? 'Free' : 'Free · runs on this computer',
        Icons.bolt_outlined,
        0.28,
      ),
      EngineCost.metered => (
        AppPalette.brandBolt,
        compact ? 'Your account' : 'Billed to your own account',
        Icons.account_balance_wallet_outlined,
        0.20,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: borderAlpha)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
