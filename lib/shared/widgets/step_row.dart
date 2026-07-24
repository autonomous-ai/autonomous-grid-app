import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_spinner.dart';
import '../../features/provider_node/presentation/engine_block.dart';

/// Where one step of a multi-step job stands.
enum StepStatus {
  /// Not started. Drawn as one dimmed line — it's context, not news.
  pending,

  /// Happening now. Lifted onto its own surface and given its explanation, so
  /// the eye lands on the one thing in progress.
  running,

  done,

  /// Broke. Keeps the surface (it's still where the user's attention belongs)
  /// and shows the reason in place of the explanation.
  failed,
}

/// One step of a job the user is watching — first-run setup, or the sign-in
/// handshake.
///
/// Shared, because those two screens are the same promise made twice: "here is
/// what I'm doing for you, and where you are in it". They used to say it in two
/// different visual languages — a checklist on one screen, an accent-filled
/// timeline with an orbiting seal on the other — which read as two products to
/// anyone signing in for the first time.
class StepRow extends StatelessWidget {
  const StepRow({
    super.key,
    required this.title,
    required this.status,
    this.detail,
  });

  final String title;
  final StepStatus status;

  /// The line under the title, shown only on the step running now or the one
  /// that broke — on the rest it's noise between the user and the point.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final running = status == StepStatus.running;
    final failed = status == StepStatus.failed;
    final pending = status == StepStatus.pending;
    final lifted = running || failed;

    final row = Padding(
      padding: EdgeInsets.fromLTRB(lifted ? 15 : 3, 11, 14, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Center(child: _StatusIcon(status: status)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: running ? FontWeight.w600 : FontWeight.w400,
                    color: pending
                        ? AppPalette.textFaint
                        : AppPalette.textPrimary,
                  ),
                ),
                if (lifted && detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: failed
                          ? theme.colorScheme.error
                          : AppPalette.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (!lifted) return Padding(padding: _gap, child: row);
    // The same rim the choice rows wear: these sit on the onboarding card's
    // white, where a fill-and-shadow surface leaves no edge at all.
    return Padding(
      padding: _gap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppGlass.surfaceFill,
          borderRadius: BorderRadius.circular(EngineSurface.radius),
          border: Border.all(color: AppGlass.lift),
        ),
        child: row,
      ),
    );
  }

  static const _gap = EdgeInsets.only(bottom: 6);
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final StepStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (status) {
      StepStatus.pending => Icon(
        Icons.circle_outlined,
        size: 13,
        color: AppPalette.textFaint,
      ),
      StepStatus.running => const AppSpinner(size: SpinnerSize.small),
      StepStatus.done => Icon(
        Icons.check_circle,
        size: 18,
        color: AppPalette.online,
      ),
      StepStatus.failed => Icon(
        Icons.error,
        size: 18,
        color: theme.colorScheme.error,
      ),
    };
  }
}
