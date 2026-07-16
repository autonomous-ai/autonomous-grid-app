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
    // A task whose result landed since the app opened gets a "new results" pill,
    // so the list itself says something arrived — you don't have to open it.
    final hasNew = ref.watch(taskDeliveryProvider).contains(widget.job.id);

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
    required this.theme,
  });

  final ScheduledJob job;
  final JobStatus status;
  final bool hasNew;
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
        // A live second line the schedule alone can't give: when it fires next,
        // or how the last run went. Only shown when there's something true to say.
        if (_liveLine(now) case final line?) ...[
          const SizedBox(height: 2),
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textFaint,
              height: 1.15,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }

  /// The one live fact worth a line: a paused task says nothing extra; a failed
  /// or blocked one leads with the failure (a blocked task's "next run" is a lie
  /// — it won't run); otherwise show when it runs next.
  String? _liveLine(DateTime now) {
    if (status == JobStatus.paused) return null;
    if (status == JobStatus.lastRunFailed || status == JobStatus.blocked) {
      return jobLastRunLine(job, now);
    }
    return jobNextRunLine(job, now) ?? jobLastRunLine(job, now);
  }
}
