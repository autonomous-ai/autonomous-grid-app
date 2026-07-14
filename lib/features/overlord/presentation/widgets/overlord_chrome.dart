import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/overlord_providers.dart';
import '../overlord_tokens.dart';
import 'ghost_button.dart';

/// The dashboard's own top strip: brand + live indicator on the left, the
/// wall clock and chrome actions on the right.
class OverlordChrome extends ConsumerWidget {
  const OverlordChrome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        const _Brand(),
        const Spacer(),
        const _Clock(),
        const SizedBox(width: 12),
        GhostButton(
          label: 'Reset layout',
          onPressed: () => ref.invalidate(overlordSnapshotProvider),
        ),
      ],
    );
  }
}

/// Title styled like the Grids section header — same app typeface and weight,
/// with the live indicator standing in for the count.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          'Overlord',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, fontSize: 20),
        ),
        const SizedBox(width: 10),
        const StatusDot(color: OverlordTokens.accent, size: 6),
        const SizedBox(width: 6),
        Text(
          'live',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: AppPalette.textFaint),
        ),
      ],
    );
  }
}

class _Clock extends ConsumerWidget {
  const _Clock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(overlordClockProvider).asData?.value;
    return Text(
      now == null ? '--:--:--' : _format(now),
      style: TextStyle(
        fontFamily: OverlordTokens.mono,
        fontSize: 13,
        color: AppPalette.textSecondary,
      ),
    );
  }

  String _format(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
