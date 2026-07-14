part of 'job_list.dart';

class _JobRow extends StatefulWidget {
  const _JobRow({
    required this.job,
    required this.selected,
    required this.onTap,
  });

  final ScheduledJob job;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_JobRow> createState() => _JobRowState();
}

class _JobRowState extends State<_JobRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(11);
    final fill = widget.selected
        ? AppPalette.cardBg
        : (_hovered ? AppSurface.hoverFill : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        decoration: BoxDecoration(color: fill, borderRadius: radius),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: StatusDot(color: _dotColor(widget.job), size: 8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _JobRowText(job: widget.job, theme: theme),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Color _dotColor(ScheduledJob job) {
    if (!job.enabled) return AppPalette.offline;
    if (job.failed) return AppPalette.warn;
    return AppPalette.online;
  }
}

class _JobRowText extends StatelessWidget {
  const _JobRowText({required this.job, required this.theme});

  final ScheduledJob job;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          job.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          describeJobCron(job.cron),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.15,
          ),
        ),
      ],
    );
  }
}
