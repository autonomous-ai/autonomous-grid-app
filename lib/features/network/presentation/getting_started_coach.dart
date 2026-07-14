import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../logic/getting_started.dart';

/// A dismissible "start here" nudge for a consumer-only account — the user who
/// joined public grids but owns none, so there's no Engines tab or setup flow to
/// lean on. It spells out, in two plain steps, how to actually use a grid.
///
/// Renders nothing unless [showGettingStartedProvider] is true (consumer-only,
/// not yet dismissed), so it can be dropped into the pane unconditionally.
class GettingStartedCoach extends ConsumerWidget {
  const GettingStartedCoach({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showGettingStartedProvider)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.waving_hand_outlined,
              size: 20,
              color: AppPalette.accent,
            ),
            const SizedBox(width: 14),
            const Expanded(child: _Steps()),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppPalette.textFaint,
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => ref
                  .read(gettingStartedDismissedProvider.notifier)
                  .dismiss(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'New here? Start in two steps',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
        SizedBox(height: 10),
        _Step(n: '1', text: 'Pick a grid from the list on the left.'),
        SizedBox(height: 6),
        _Step(n: '2', text: 'Tap “Try it” to send a message and see the answer.'),
        SizedBox(height: 10),
        Text(
          'Want to share your own computer’s AI? Tap “+ New grid”.',
          style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final String n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppPalette.accent,
            shape: BoxShape.circle,
          ),
          child: Text(
            n,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
