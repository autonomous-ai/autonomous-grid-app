import 'package:flutter/material.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../logic/log_format.dart';
import 'command_detail_dialog.dart';

/// One command in the Debug list: what ran, how it ended, and — on a click —
/// everything the line couldn't hold (see [showCommandDetailDialog]).
///
/// The command reads as plain text here rather than as selectable text, which
/// is what it used to be: a `SelectableText` eats the tap that opens the row,
/// and the line it let you copy was the truncated one. Selecting and copying
/// moved to the dialog, where the whole argv and the bodies are.
class LogTile extends StatefulWidget {
  const LogTile({super.key, required this.log});

  final GridCommandLog log;

  @override
  State<LogTile> createState() => _LogTileState();
}

class _LogTileState extends State<LogTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // list item — must self-watch to follow flips.
    final theme = Theme.of(context);
    final log = widget.log;

    // A button, so a screen reader offers it as one; the command text under it
    // stays the announcement — a label here would talk over it.
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => showCommandDetailDialog(context, log),
          child: GlassCard(
            style: GlassCardStyle.inset,
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LogStatusIcon(status: log.status),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        log.command,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: AppFont.mono,
                          fontFamilyFallback: AppFont.monoFallback,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _Meta(log: log),
                    // Held open whether or not the cursor is here, so a row
                    // doesn't reflow the instant it is pointed at.
                    SizedBox(
                      width: 22,
                      child: _hovered
                          ? Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: AppPalette.textSecondary,
                            )
                          : null,
                    ),
                  ],
                ),
                if (log.error != null) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 26, right: 22),
                    child: Text(
                      log.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontFamily: AppFont.mono,
                        fontFamilyFallback: AppFont.monoFallback,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Running / succeeded / failed, as one glyph. Shared with the detail dialog so
/// a row and the panel it opens can never disagree about how a command ended.
class LogStatusIcon extends StatelessWidget {
  const LogStatusIcon({super.key, required this.status});

  final CliCallStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette.online — follow theme flips.
    return switch (status) {
      CliCallStatus.running => const AppSpinner(),
      CliCallStatus.success => Icon(
        Icons.check_circle,
        size: 16,
        color: AppPalette.online,
      ),
      CliCallStatus.failed => Icon(
        Icons.error,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      ),
    };
  }
}

/// The kind, the clock time, and how it ended — the trailing column of a row.
class _Meta extends StatelessWidget {
  const _Meta({required this.log});

  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette.textFaint — follow theme flips.
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: AppPalette.textFaint,
      fontFamily: AppFont.mono,
      fontFamilyFallback: AppFont.monoFallback,
      fontSize: 11.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(log.kind.name, style: style),
        const SizedBox(height: 2),
        Text(_detail(log), style: style),
      ],
    );
  }

  String _detail(GridCommandLog log) {
    final time = formatLogTime(log.startedAt);
    if (log.status == CliCallStatus.running) return '$time · running…';
    final dur = log.duration == null
        ? ''
        : ' · ${formatLogDuration(log.duration!)}';
    final code = switch (log.exitCode) {
      null => '',
      final c when log.kind == CliCallKind.http => ' · HTTP $c',
      final c => ' · exit $c',
    };
    return '$time$dur$code';
  }
}
