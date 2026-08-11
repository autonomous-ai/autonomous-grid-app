import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/detail_widgets.dart';
import '../logic/log_format.dart';
import 'log_status_icon.dart';

/// Everything behind one row of the Debug list, opened by clicking it.
///
/// The list has to stay scannable, so a row is one line — and one line is
/// exactly what cannot answer the two questions a failing command raises: what
/// was really passed, and what went over the wire. Both are here: every argv
/// token on its own line (so an argument containing spaces reads as the single
/// argument it was), the named parameters, and the request/response bodies,
/// re-indented when they are JSON.
///
/// Never shows a secret. Env values are dropped where the call is recorded —
/// only their names travel — and request headers, where the bearer key sits,
/// are not recorded at all. See [CommandDetail].
Future<void> showCommandDetailDialog(
  BuildContext context,
  GridCommandLog log,
) => showDialog<void>(
  context: context,
  builder: (_) => _DetailDialog(opened: log),
);

class _DetailDialog extends ConsumerWidget {
  const _DetailDialog({required this.opened});

  /// The entry as it stood when the row was clicked. Kept as the fallback for
  /// [_current] — the buffer is a ring, and Clear empties it outright.
  final GridCommandLog opened;

  /// This entry as it stands *now*. A command can still be running when its row
  /// is opened — an agent turn runs for minutes — and a panel frozen at the
  /// moment of the click would sit on "Still running" after it had answered.
  GridCommandLog _current(List<GridCommandLog> logs) {
    for (final entry in logs) {
      if (entry.id == opened.id) return entry;
    }
    return opened;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Dialog content: watch brightness so tokens re-color on a theme flip.
    AppTheme.watch(context);
    final log = ref.watch(commandLogProvider.select(_current));
    // Wider than a form dialog: this one holds argv and JSON, which wrap badly
    // at 460. Capped against the window so a 13" screen keeps page either side.
    //
    // The *title* is given it too, not only the content. An `AlertDialog` sizes
    // itself to the widest of the two, so a long URL on one line stretched the
    // dialog past this figure and left the body sitting narrow inside it.
    final width = math.min(640.0, MediaQuery.sizeOf(context).width - 120);

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 20, 16),
      title: SizedBox(
        width: width,
        child: _Header(log: log),
      ),
      content: SizedBox(
        width: width,
        // The body scrolls on its own so the command line and its status stay
        // put while a long payload moves under them.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.66,
          ),
          child: SingleChildScrollView(child: _Body(log: log)),
        ),
      ),
      actions: [
        // Not a transcript of the panel: what a terminal will take. A request
        // copies as the `curl` that repeats it, a spawned process as its own
        // command line — with how it ended on comment lines above, so the same
        // copy still tells a bug report what happened.
        CopyButton(value: logAsCommand(log), label: copyActionLabel(log)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
      // Named for the screen reader: the title is a status glyph over a command
      // line, which announces as neither on its own.
      semanticLabel: 'Command details',
    );
  }
}

/// The status glyph, the kind, and the command itself — selectable here because
/// the row in the list is a button and cannot be.
class _Header extends StatelessWidget {
  const _Header({required this.log});

  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            LogStatusIcon(status: log.status),
            const SizedBox(width: 8),
            Text(
              switch (log.kind) {
                CliCallKind.http => 'Network request',
                _ => 'Command',
              },
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: AppFont.medium,
                color: AppPalette.textSecondary,
              ),
            ),
            const Spacer(),
            AppIconButton(
              icon: Icons.close,
              size: 18,
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(
          log.command,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: AppFont.mono,
            fontFamilyFallback: AppFont.monoFallback,
            color: AppPalette.textPrimary,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.log});

  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final detail = log.detail;
    // The URL's own query string belongs with the recorded parameters: to
    // whoever is reading, `?json=true` is a parameter like any other. The env
    // row is built from the names here rather than stored as a sentence, so the
    // copied command can turn them back into `KEY="$KEY"`.
    final params = {
      ...logQueryParams(log),
      ...detail.params,
      if (detail.envKeys.isNotEmpty) 'env': envNamesLabel(detail.envKeys),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Facts(log: log),
        if (log.error case final error?) ...[
          const SizedBox(height: 18),
          _TextSection(title: 'What went wrong', body: error, isError: true),
        ],
        if (detail.args.isNotEmpty) ...[
          const SizedBox(height: 18),
          // One argument per line: joined, there is no telling whether
          // `--name My home grid` was one argument or three.
          _TextSection(title: 'Arguments', body: detail.args.join('\n')),
        ],
        if (params.isNotEmpty) ...[
          const SizedBox(height: 18),
          DetailSection(
            title: 'Parameters',
            children: [
              for (final entry in params.entries)
                MetaRow(label: entry.key, value: entry.value),
            ],
          ),
        ],
        if (detail.requestBody case final body?) ...[
          const SizedBox(height: 18),
          _TextSection(title: 'What was sent', body: prettyBody(body)),
        ],
        if (detail.responseBody case final body?) ...[
          const SizedBox(height: 18),
          _TextSection(title: 'What came back', body: prettyBody(body)),
        ],
        if (detail.isEmpty && log.error == null && params.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: _NothingElse(kind: log.kind),
          ),
      ],
    );
  }
}

/// When it ran, how long it took, and how it ended.
class _Facts extends StatelessWidget {
  const _Facts({required this.log});

  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    final isHttp = log.kind == CliCallKind.http;
    return DetailSection(
      title: 'Details',
      children: [
        MetaRow(label: 'Started', value: formatLogTime(log.startedAt)),
        if (log.duration case final d?)
          MetaRow(label: 'Took', value: formatLogDuration(d))
        else if (log.status == CliCallStatus.running)
          const MetaRow(label: 'Took', value: 'Still running'),
        if (log.exitCode case final code?)
          MetaRow(
            label: isHttp ? 'Response status' : 'Exit code',
            value: '$code',
          ),
      ],
    );
  }
}

/// A block of monospace text under the same heading the fact cards wear, with
/// its own copy button — argv, a payload, a server's error body.
///
/// Monospace throughout because none of these are prose: an aligned JSON key
/// and a stderr line both stop reading as structure in a proportional font.
/// [isError] tints the block, so a failure keeps the red it has in the list.
class _TextSection extends StatelessWidget {
  const _TextSection({
    required this.title,
    required this.body,
    this.isError = false,
  });

  final String title;
  final String body;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return DetailSection(
      title: title,
      trailing: CopyIconButton(value: body),
      children: [
        // Full width, or the card shrink-wraps this text and every panel ends
        // at a different place down the dialog.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: SelectableText(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isError ? theme.colorScheme.error : AppPalette.textPrimary,
              fontFamily: AppFont.mono,
              fontFamilyFallback: AppFont.monoFallback,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown when the summary line really is the whole record — better than an
/// empty panel that reads as something failing to load.
class _NothingElse extends StatelessWidget {
  const _NothingElse({required this.kind});

  final CliCallKind kind;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A plain GET has no arguments to speak of; calling its empty record "no
    // arguments" reads as something having gone missing.
    return Text(
      switch (kind) {
        CliCallKind.http =>
          'This request carried no parameters and no body — the line above is '
              'the whole record.',
        _ =>
          'This command ran with no arguments and sent nothing — the line '
              'above is the whole record.',
      },
      style: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 12.5,
        height: 1.45,
      ),
    );
  }
}
