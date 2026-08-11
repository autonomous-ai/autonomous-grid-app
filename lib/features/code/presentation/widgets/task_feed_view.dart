import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/task_event_lines.dart';
import '../../logic/task_follow_controller.dart';

/// A task's live view: what the agent said, and what it did, as it happens.
///
/// Newest last and scrolled to the bottom, the way a terminal reads — a task is
/// watched, not browsed.
class TaskFeedView extends StatelessWidget {
  const TaskFeedView({super.key, required this.feed});

  final TaskFeed feed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final lines = [
      for (final event in feed.events)
        if (taskEventLine(event) case final line?) (event.seq, line),
    ];

    if (lines.isEmpty) {
      return _Waiting(status: feed.status);
    }
    return ListView.builder(
      reverse: true,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final (seq, line) = lines[lines.length - 1 - index];
        return _Line(key: ValueKey(seq), text: line.text, tone: line.tone);
      },
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: AppPalette.textFaint,
          ),
        ),
      ),
    );
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
