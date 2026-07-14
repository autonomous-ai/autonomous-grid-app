import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/scheduled_jobs_controller.dart';

/// Warns when tasks are saved but nothing is there to fire them.
///
/// Hermes runs scheduled tasks from a background service; if it isn't up, the
/// tasks sit there looking healthy and never run. Saying "Running to schedule"
/// then would be a lie — so this says the truth and offers the one-click fix.
class SchedulerBanner extends ConsumerStatefulWidget {
  const SchedulerBanner({super.key});

  @override
  ConsumerState<SchedulerBanner> createState() => _SchedulerBannerState();
}

class _SchedulerBannerState extends ConsumerState<SchedulerBanner> {
  bool _starting = false;

  Future<void> _start() async {
    setState(() => _starting = true);
    final error = await ref
        .read(scheduledJobsProvider.notifier)
        .startScheduler();
    if (!mounted) return;
    setState(() => _starting = false);
    if (error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(schedulerRunningProvider).asData?.value;
    // Say nothing while we don't know yet — a banner that flashes on every open
    // would cry wolf.
    if (running == null || running) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppPalette.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: AppPalette.warn,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Scheduled tasks are saved, but nothing is running them on this '
              'computer yet.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _starting ? null : _start,
            child: Text(_starting ? 'Starting…' : 'Turn it on'),
          ),
        ],
      ),
    );
  }
}
