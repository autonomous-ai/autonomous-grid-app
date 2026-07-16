import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/job_schedule.dart';
import '../../logic/job_status.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';
import '../../logic/task_delivery.dart';
import 'scheduled_pill_choice.dart';
import 'status_pill.dart';

part 'job_row.dart';

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

  bool _matchesFilter(ScheduledJob job) {
    // Filter by what the task will actually do, not the raw enabled flag: a
    // blocked task is "enabled" but won't run, so it belongs with the paused
    // ones under "Paused", never under "Running".
    final willRun = switch (jobStatusOf(job)) {
      JobStatus.running || JobStatus.lastRunFailed => true,
      JobStatus.blocked || JobStatus.paused => false,
    };
    return switch (_filter) {
      JobFilter.all => true,
      JobFilter.active => willRun,
      JobFilter.paused => !willRun,
    };
  }

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
          runSpacing: 8,
          children: [
            for (final filter in JobFilter.values)
              ScheduledPillChoice(
                label: Text(filter.label),
                selected: filter == _filter,
                onTap: () => setState(() => _filter = filter),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Search tasks',
            prefixIcon: const Icon(Icons.search_rounded, size: 17),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 34,
              minHeight: 34,
            ),
            filled: true,
            fillColor: AppPalette.cardBg,
            contentPadding: const EdgeInsets.symmetric(vertical: 9),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          // Cross-fade when the filter changes, so tasks entering and leaving the
          // list read as a switch rather than a jump. Keyed by the filter alone —
          // typing in search rebuilds the same list in place without a fade.
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: jobs.isEmpty
                ? _NoMatches(key: ValueKey('empty-${_filter.name}'))
                : ListView.separated(
                    key: ValueKey('list-${_filter.name}'),
                    padding: EdgeInsets.zero,
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, i) => _JobRow(
                      // Key by job id so a row's State (and its
                      // AnimatedContainer) stays with its job across rebuilds,
                      // instead of being recycled by list position.
                      key: ValueKey(jobs[i].id),
                      job: jobs[i],
                      selected: jobs[i].id == selected,
                      onTap: () => ref
                          .read(selectedJobIdProvider.notifier)
                          .select(jobs[i].id),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 24),
      child: Text(
        'No tasks match that.',
        style: TextStyle(color: AppPalette.textFaint, fontSize: 12.5),
      ),
    );
  }
}
