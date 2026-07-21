import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// A titled engine block — a card with an icon + title header so the serve paths
/// (built-in llama.cpp, a hosted API provider, each detected framework, your own
/// engine) are easy to tell apart. Shared by every block in the Engines tab.
///
/// Dressed like the rest of the app's content surfaces rather than with
/// Material's `Card`: `AppGlass.surfaceFill` at radius 14, lifted by
/// `AppGlass.cardShadow` and carrying **no border** — depth in this app comes
/// from the shadow, never from a stroke (see `ExtensionTileSurface`, the same
/// recipe the Plugins rows use).
class EngineBlock extends StatelessWidget {
  const EngineBlock({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  /// A badge beside the title — today the cost chip, so what an engine spends
  /// (this machine, or the user's vendor account) is visible while choosing it
  /// rather than only in the prose at the foot of the form.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return EngineSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  icon,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The chip sits on the title's baseline row and wraps
                    // below it on a narrow pane rather than squeezing the
                    // title to an ellipsis.
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        ?trailing,
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// The shared surface every block on this tab sits on.
///
/// One place for the recipe so the blocks, the notes between them and the
/// failure card can't drift apart: fill, radius 14, the app's ambient card
/// shadow, and no stroke. Padding matches the row primitive the Plugins tab
/// uses — slightly tighter on the right, where a trailing control usually sits.
class EngineSurface extends StatelessWidget {
  const EngineSurface({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// The tab's standard block padding.
  static const EdgeInsets blockPadding = EdgeInsets.fromLTRB(15, 14, 14, 15);

  /// Radius shared by every block, so a nested field (radius 12) is never
  /// rounder than the box holding it.
  static const double radius = 14;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(padding: padding ?? blockPadding, child: child),
    );
  }
}

/// Like [EngineBlock] but collapsed by default — the header is tappable and the
/// form is revealed on demand. Keeps an advanced path (e.g. "connect your own
/// engine") out of the way until the user wants it.
class CollapsibleEngineBlock extends StatelessWidget {
  const CollapsibleEngineBlock({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(EngineSurface.radius),
      child: EngineSurface(
        // The tile brings its own padding; the surface only supplies the fill.
        padding: EdgeInsets.zero,
        child: Theme(
          // Drop ExpansionTile's default divider lines so it reads as one card.
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            leading: Icon(
              icon,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            tilePadding: const EdgeInsets.fromLTRB(15, 2, 14, 2),
            childrenPadding: const EdgeInsets.fromLTRB(15, 0, 14, 15),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            title: Text(title, style: theme.textTheme.titleMedium),
            subtitle: Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            children: [child],
          ),
        ),
      ),
    );
  }
}

/// A block's Start button, carrying the reason it can't run yet as a tooltip on
/// the disabled button — a greyed-out button that never says why is a dead end
/// for a first-time user.
///
/// Shared by every add-engine block: they all disable Start for the same class
/// of reason (a missing key, nothing picked, or an engine already running here).
class EngineStartButton extends StatelessWidget {
  const EngineStartButton({
    super.key,
    required this.label,
    required this.blockedReason,
    required this.onPressed,
  });

  final String label;

  /// Why the button is disabled, or null when it can start.
  final String? blockedReason;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final reason = blockedReason;
    final button = FilledButton.icon(
      onPressed: reason == null ? onPressed : null,
      icon: const Icon(Icons.play_arrow),
      label: Text(label),
    );
    if (reason == null) return button;
    return Tooltip(message: reason, child: button);
  }
}
