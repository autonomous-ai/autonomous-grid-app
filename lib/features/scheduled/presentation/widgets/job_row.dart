part of 'job_list.dart';

class _JobRow extends ConsumerStatefulWidget {
  const _JobRow({
    super.key,
    required this.job,
    required this.selected,
    required this.onTap,
  });

  final ScheduledJob job;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_JobRow> createState() => _JobRowState();
}

class _JobRowState extends ConsumerState<_JobRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(11);
    // Selection paints instantly; only hover fades. When these shared one
    // animated fill, switching rows crossfaded the old row's selected tint out
    // while the new row's faded in — two rows lit at once, the "double flash".
    // A selected row is a hard state change, so it should not animate at all.
    final status = jobStatusOf(widget.job);
    // A task with a result the user hasn't opened yet gets a "new results" pill,
    // so the list itself says something arrived — you don't have to open it. The
    // flag is persisted and clears when the chat is read, not on app restart.
    final hasNew = ref.watch(taskUnreadProvider).contains(widget.job.id);
    // What that result actually said. Only read when there's an unread one: the
    // headline answers "is this worth opening?", which a task you've already
    // read isn't asking.
    final headline = hasNew
        ? ref.watch(
            taskInboxProvider.select((all) => all[widget.job.id]?.summary),
          )
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: DecoratedBox(
        // Selected: a solid tint, drawn the instant selection lands.
        decoration: BoxDecoration(
          color: widget.selected ? AppPalette.cardBg : Colors.transparent,
          borderRadius: radius,
        ),
        child: AnimatedContainer(
          // Hover only — and never over a selected row, so hovering the open
          // task doesn't stack a second tint on it.
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: (_hovered && !widget.selected)
                ? AppSurface.hoverFill
                : Colors.transparent,
            borderRadius: radius,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.onTap,
              // The fill above is the only selection/hover signal. Ink splash and
              // highlight would paint a second, differently-timed flash over it,
              // so drop them.
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: StatusDot(
                        color: jobStatusColor(status),
                        size: 8,
                        // A live task breathes; a paused/failed one holds still.
                        pulsing: status == JobStatus.running,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _JobRowText(
                        job: widget.job,
                        status: status,
                        hasNew: hasNew,
                        headline: headline,
                        theme: theme,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _JobRowText extends StatelessWidget {
  const _JobRowText({
    required this.job,
    required this.status,
    required this.hasNew,
    required this.headline,
    required this.theme,
  });

  final ScheduledJob job;
  final JobStatus status;
  final bool hasNew;

  /// The opening line of the unread result, when there is one to quote. Null on
  /// a task with nothing new, and empty for a run that produced no answer.
  final String? headline;

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // "New results" outranks the state pill — it's the thing to act on now, and
    // a running task's "On" is the least surprising label to drop.
    final pill = hasNew
        ? StatusPill(
            label: 'New results',
            color: AppPalette.accent,
            icon: Icons.auto_awesome_rounded,
          )
        : StatusPill(
            label: jobStatusLabel(status),
            color: jobStatusColor(status),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                job.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
            ),
            const SizedBox(width: 8),
            pill,
          ],
        ),
        const SizedBox(height: 4),
        Text(
          describeJobSchedule(job.cron),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.15,
          ),
        ),
        // A live second line the schedule alone can't give: what the unread
        // result says, or when it fires next, or how the last run went. Only
        // shown when there's something true to say.
        if (_liveLine(now) case final line?) ...[
          const SizedBox(height: 2),
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              // The quoted result is the reason to open the row, so it reads a
              // step brighter than the timing lines it replaces.
              color: _quotesResult
                  ? AppPalette.textSecondary
                  : AppPalette.textFaint,
              height: 1.15,
              fontFeatures: _quotesResult
                  ? null
                  : const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }

  /// Whether the second line is the answer itself rather than a time — prose
  /// wants neither the tabular figures nor the faint colour a clock does.
  bool get _quotesResult => hasNew && (headline?.isNotEmpty ?? false);

  /// The one live fact worth a line: an unread result leads with what it found
  /// (the reason to open it at all); a paused task says nothing extra; a failed
  /// or blocked one leads with the failure (a blocked task's "next run" is a lie
  /// — it won't run); otherwise show when it runs next.
  String? _liveLine(DateTime now) {
    if (_quotesResult) return headline;
    if (status == JobStatus.paused) return null;
    if (status == JobStatus.lastRunFailed || status == JobStatus.blocked) {
      return jobLastRunLine(job, now);
    }
    return jobNextRunLine(job, now) ?? jobLastRunLine(job, now);
  }
}
