import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/job_schedule.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';

/// Which tasks the list shows.
enum JobFilter {
  all('All'),
  active('Running'),
  paused('Paused');

  const JobFilter(this.label);

  final String label;
}

/// The saved tasks: a filter, a search box, then a row per task. Selecting one
/// opens it in the pane to the right.
class JobList extends ConsumerStatefulWidget {
  const JobList({super.key, required this.jobs});

  final List<ScheduledJob> jobs;

  @override
  ConsumerState<JobList> createState() => _JobListState();
}

class _JobListState extends ConsumerState<JobList> {
  final _search = TextEditingController();
  JobFilter _filter = JobFilter.all;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ScheduledJob> get _visible {
    final query = _query.trim().toLowerCase();
    return [
      for (final job in widget.jobs)
        if (_matchesFilter(job) && _matchesQuery(job, query)) job,
    ];
  }

  bool _matchesFilter(ScheduledJob job) => switch (_filter) {
    JobFilter.all => true,
    JobFilter.active => job.enabled,
    JobFilter.paused => !job.enabled,
  };

  bool _matchesQuery(ScheduledJob job, String query) =>
      query.isEmpty ||
      job.name.toLowerCase().contains(query) ||
      job.prompt.toLowerCase().contains(query);

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedJobIdProvider);
    final jobs = _visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final filter in JobFilter.values)
              ChoiceChip(
                label: Text(filter.label),
                selected: filter == _filter,
                onSelected: (_) => setState(() => _filter = filter),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Search tasks',
            prefixIcon: Icon(Icons.search_rounded, size: 17),
            prefixIconConstraints: BoxConstraints(minWidth: 34, minHeight: 34),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: jobs.isEmpty
              ? const _NoMatches()
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: jobs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, i) => _JobRow(
                    job: jobs[i],
                    selected: jobs[i].id == selected,
                    onTap: () => ref
                        .read(selectedJobIdProvider.notifier)
                        .select(jobs[i].id),
                  ),
                ),
        ),
      ],
    );
  }
}

/// One task in the list: a state dot, its name, and when it next runs.
class _JobRow extends StatelessWidget {
  const _JobRow({
    required this.job,
    required this.selected,
    required this.onTap,
  });

  final ScheduledJob job;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(10);
    return Material(
      color: selected ? AppSurface.selectedFill : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: StatusDot(color: _dotColor(job), size: 8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      describeJobCron(job.cron),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Green while it's running to schedule, amber when the last run failed, grey
  /// when the user paused it — the state you'd want to spot from across the list.
  static Color _dotColor(ScheduledJob job) {
    if (!job.enabled) return AppPalette.offline;
    if (job.failed) return AppPalette.warn;
    return AppPalette.online;
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 24),
      child: Text(
        'No tasks match that.',
        style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}
