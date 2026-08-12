import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/task_event_lines.dart';
import '../../logic/task_follow_controller.dart';

/// How many lines a running task shows under its turn.
///
/// The tail, not the lot: "what is it doing" is answered by the last handful of
/// steps, and a task that makes three hundred tool calls would otherwise push
/// the question that started it off the top of the screen.
const int kLiveTaskLines = 14;

/// What a task's agent said and did, line by line.
///
/// Not a scroller. It sits inside the transcript, under the turn that asked for
/// it, so it grows that turn rather than trapping a second scrollbar inside one
/// — which is also why [tail] exists: a live task shows its last few lines, and
/// a finished one shows the lot only when somebody asks to see it.
class TaskFeedView extends StatelessWidget {
  const TaskFeedView({super.key, required this.feed, this.tail});

  final TaskFeed feed;

  /// How many lines from the end to show, or null for all of them.
  final int? tail;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final lines = [
      for (final event in feed.events)
        if (taskEventLine(event) case final line?) (event.seq, line),
    ];

    if (lines.isEmpty) return _Waiting(status: feed.status);

    final limit = tail;
    final hidden = (limit == null || lines.length <= limit)
        ? 0
        : lines.length - limit;
    final shown = hidden == 0 ? lines : lines.sublist(hidden);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Said rather than silently dropped: a feed that starts mid-run reads
        // as a run that started there.
        if (hidden > 0)
          _Line(
            text: '$hidden earlier ${hidden == 1 ? 'step' : 'steps'}',
            tone: TaskLineTone.note,
          ),
        for (final (seq, line) in shown)
          _Line(key: ValueKey(seq), text: line.text, tone: line.tone),
      ],
    );
  }
}

/// Nothing has arrived yet — which for a queued task is where it stays until a
/// computer picks it up, so the wait is named rather than left as a spinner.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.status});

  final FollowStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final message = switch (status) {
      FollowConnecting() =>
        'Waiting for a computer on the grid to pick this up. It can sit here a '
            'while — nothing is held open, so you can close the app and come '
            'back.',
      FollowLive() => 'Working. Nothing to show yet.',
      FollowFinished() => 'This finished with nothing to show.',
      FollowLost(:final message) => message,
    };
    return _Line(text: message, tone: TaskLineTone.note);
  }
}

/// One line, styled by what kind of thing it is.
class _Line extends StatelessWidget {
  const _Line({super.key, required this.text, required this.tone});

  final String text;
  final TaskLineTone tone;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final mono = tone == TaskLineTone.step;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: mono ? 12.5 : 13,
          height: 1.45,
          // Mono for a tool call, because it is a command and a path — the
          // strings where `l/1/I` has to be told apart. Prose stays in the
          // reading face.
          fontFamily: mono ? AppFont.mono : null,
          fontFamilyFallback: mono ? AppFont.monoFallback : null,
          fontWeight: tone == TaskLineTone.verdict
              ? AppFont.medium
              : FontWeight.w400,
          color: switch (tone) {
            TaskLineTone.prose => AppPalette.textPrimary,
            TaskLineTone.step => AppPalette.textSecondary,
            TaskLineTone.note => AppPalette.textFaint,
            TaskLineTone.verdict => AppPalette.textPrimary,
          },
        ),
      ),
    );
  }
}
