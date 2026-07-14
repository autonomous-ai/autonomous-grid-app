import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/status_dot.dart';
import '../../logic/job_schedule.dart';
import '../../logic/scheduled_job.dart';
import '../../logic/scheduled_jobs_controller.dart';
import 'scheduled_pill_choice.dart';

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
          runSpacing: 8,
          children: [
            for (final filter in JobFilter.values)
              ScheduledPillChoice(
                label: Text(filter.label),
                selected: filter == _filter,
                icon: filter == _filter ? Icons.check_rounded : null,
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
            border: _searchBorder(),
            enabledBorder: _searchBorder(),
            focusedBorder: _searchBorder(AppPalette.divider),
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

  OutlineInputBorder _searchBorder([Color color = AppPalette.divider]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: color),
      );
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
