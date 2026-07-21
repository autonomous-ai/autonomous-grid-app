import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';

/// The "you may use this grid, but not share on it" screen — a grid someone else
/// owns and hasn't granted this account the provider role on.
///
/// Replaces a lone sentence in a card, which answered "why is there no form?"
/// but left the more useful question — *what can I do instead?* — unanswered on
/// an otherwise empty screen. Two columns: what this account may do here, and
/// the ways forward. Nothing here needs a permission we don't have, so the
/// screen never dead-ends.
class SharingLockedView extends ConsumerWidget {
  const SharingLockedView({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Side by side when there's room; stacked on a narrow settings pane, so
        // neither column is squeezed to a few words per line.
        final wide = constraints.maxWidth >= 720;
        final permissions = _PermissionSummary(network: network);
        final actions = _WaysForward(network: network);

        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [permissions, const SizedBox(height: 16), actions],
          );
        }
        // Both columns size to their own content. Stretching them to a common
        // height (IntrinsicHeight + an Expanded card) only moved the ragged gap
        // from one column to the other, and cost a bounded-height caveat that
        // had to be threaded through the widgets below — not worth it for a
        // difference of a few tens of pixels.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 6, child: permissions),
            const SizedBox(width: 16),
            Expanded(flex: 5, child: actions),
          ],
        );
      },
    );
  }
}

/// The left column: the headline, then this account's actual capabilities on
/// this grid as a checklist. The checklist is the part that answers what the
/// user is really asking — a flat "you can't share" leaves them guessing whether
/// anything works here at all.
class _PermissionSummary extends StatelessWidget {
  const _PermissionSummary({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _ViewOnlyBadge(),
              const SizedBox(height: 12),
              Text(
                'You can use this grid, but not share on it',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              // "this grid" is safe to say here — GridScopeBar names it directly
              // above. Repeating the name in both would read as a stutter, and
              // a long grid name would wreck this sentence.
              Text(
                'Its owner hasn’t allowed your account to run a model here yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'WHAT YOU CAN DO HERE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 12),
              const _PermissionRow(
                allowed: true,
                label: 'Use models other people share',
              ),
              const _PermissionRow(
                allowed: true,
                label: 'See this grid’s members and models',
              ),
              const _PermissionRow(
                allowed: false,
                label: 'Share a model from this computer',
                note: 'Needs permission from the owner',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The "view only" pill above the headline — state as form, not just words, so
/// the situation registers before the sentence is read.
class _ViewOnlyBadge extends StatelessWidget {
  const _ViewOnlyBadge();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: AppCard.inset,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppCard.insetHair),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              // Not "on this grid" — the scope bar above already says which.
              'View only',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One capability line: a tick or a cross, the capability, and — when denied —
/// why. Denied rows are dimmed so the two groups separate at a glance.
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.allowed, required this.label, this.note});

  final bool allowed;
  final String label;
  final String? note;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            allowed ? Icons.check_circle_outline : Icons.lock_outline,
            size: 16,
            color: allowed ? AppPalette.online : muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              // Full-strength ink on both rows. Dimming the denied label put
              // its icon, label and note at one grey (~7:1 each, dark), so
              // nothing led the eye and the row read as switched-off rather
              // than as a fact about this account. The lock icon and the note
              // carry the "denied" meaning; the label is information either
              // way and stays as legible as the rows above it.
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                note!,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The right column: the ways out of this state, in the order most people should
/// try them. Every step here is something the app can actually carry out — we
/// deliberately don't offer a "request access" button, because there's no API
/// behind it (see the note in `ProviderView`).
class _WaysForward extends ConsumerWidget {
  const _WaysForward({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.hero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'WHAT YOU CAN DO NEXT',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 14),
          // One step, so it carries no number: a "1" with nothing after it
          // promises a sequence that doesn't exist. The old step 2 pointed at
          // the set-up card below, which this state no longer shows — preparing
          // this computer with a multi-GB download readies you for something you
          // still can't do here, and it read as the main action while the real
          // way forward sat beside it.
          _Step(
            title: 'Share on a grid of your own',
            body:
                'Every account has at least one grid it owns, and you can run '
                'any engine you like there.',
            action: 'Open my grids',
            icon: Icons.bolt,
            onPressed: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.grids),
            emphasised: true,
          ),
          const SizedBox(height: 14),
          Text(
            'To share here instead, ask an owner of ${network.name} to give '
            'your account permission to run a model.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The way forward out of this state.
///
/// Was a numbered step in a two-step column. The second step pointed at the
/// set-up card this state no longer shows, so the sequence — and with it the
/// number, the tick-when-done marker, and the note variant that had no button —
/// went with it. What's left is one card with one action.
class _Step extends StatelessWidget {
  const _Step({
    required this.title,
    required this.body,
    required String this.action,
    required IconData this.icon,
    required VoidCallback this.onPressed,
    this.emphasised = false,
  });

  final String title;
  final String body;
  final String? action;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// The recommended step wears the filled button; the rest stay outlined so the
  /// column has one clear lead action.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.all(13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The lead glyph, no longer a step number — it marks the card rather
          // than counting it.
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppPalette.accentOnSurface.withValues(alpha: 0.14),
            ),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 13,
              color: AppPalette.accentOnSurface,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                // A note-style step has no button of its own — see [_Step.note].
                if (action case final label?) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: emphasised
                        ? FilledButton.icon(
                            onPressed: onPressed,
                            icon: Icon(icon, size: 16),
                            label: Text(label),
                          )
                        : OutlinedButton.icon(
                            onPressed: onPressed,
                            icon: Icon(icon, size: 16),
                            label: Text(label),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
