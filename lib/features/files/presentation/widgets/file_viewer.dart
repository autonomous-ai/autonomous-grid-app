import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/code/code_highlight.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/code_text_scope.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../logic/file_preview.dart';

/// The file on screen: its text, numbered and coloured, in the panel's main
/// region.
///
/// Read-only, and the colouring is the same [CodeHighlight] the transcript and
/// the diff already use — so a file read here looks like the same file quoted in
/// an answer, rather than like a third rendering of source in one window.
class FileViewer extends ConsumerWidget {
  const FileViewer({super.key, required this.path});

  /// The absolute path of the file to show, or null before one is picked.
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = this.path;
    if (path == null) {
      return const EmptyState(
        icon: LucideIcons.fileText,
        title: 'No file open',
        message: 'Pick a file from the tree to read it here.',
        compact: true,
      );
    }

    return switch (ref.watch(filePreviewProvider(path))) {
      AsyncData(:final value) => _Preview(
        preview: value,
        language: languageForPath(path),
      ),
      AsyncError(:final error) => _Failed('$error'),
      _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
    };
  }
}

/// One resolved preview, in whichever of its four shapes came back.
class _Preview extends StatelessWidget {
  const _Preview({required this.preview, required this.language});

  final FilePreview preview;

  /// The grammar to colour with, or '' for a file whose extension we have none
  /// for — a `.log`, a `Makefile`, anything the highlighter doesn't know.
  final String language;

  @override
  Widget build(BuildContext context) => switch (preview) {
    FilePreviewText(:final lines) when lines.isEmpty => const _Note(
      'This file is empty.',
    ),
    FilePreviewText(:final lines, :final truncated) => _Source(
      lines: lines,
      truncated: truncated,
      language: language,
    ),
    FilePreviewBinary() => const _Note(
      'This is not a text file, so there is nothing to show. Open it to see it '
      'in the app that handles it.',
    ),
    FilePreviewTooBig(:final bytes) => _Note(
      'This file is ${_megabytes(bytes)} — too big to read here. Open it in '
      'your editor instead.',
    ),
    FilePreviewFailed(:final message) => _Failed(message),
  };
}

String _megabytes(int bytes) => '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

/// The source itself: a gutter of line numbers beside the text.
///
/// Two text blocks rather than a row per line, so the whole file scrolls and
/// selects as one thing. [kFilePreviewMaxLines] is what keeps that affordable —
/// the cost here is one layout pass over the file.
///
/// Whole-file, and that is also why it is coloured in one call rather than a
/// line at a time the way the diff is: a line handed to the grammar on its own
/// can't know it sits inside a block comment or a multi-line string, and a file
/// that opens with a licence header would come up coloured as code. Measured at
/// ~60µs a line once the engine is warm — 130ms for the 2,000-line ceiling,
/// paid once when the file opens and never again while it is on screen, since
/// [CodeHighlight] remembers the answer.
class _Source extends StatefulWidget {
  const _Source({
    required this.lines,
    required this.truncated,
    required this.language,
  });

  final List<String> lines;
  final bool truncated;
  final String language;

  @override
  State<_Source> createState() => _SourceState();
}

class _SourceState extends State<_Source> {
  /// The vertical scroll, held so the scrollbar can be told which of the two
  /// nested views it belongs to. Left to find one itself it would attach to
  /// whichever it saw first — the horizontal one — and draw a bar that moves
  /// the wrong way.
  final _vertical = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final lines = widget.lines;
    final gutter = AppFont.codeStyle(color: AppPalette.textFaint, height: 1.5);
    final code = AppFont.codeStyle(color: AppPalette.textPrimary, height: 1.5);
    final source = lines.join('\n');
    // The theme only ever contributes colour, so every span keeps [code]'s face,
    // size and 1.5 line height — which is what holds each line level with its
    // number in the gutter beside it.
    final coloured = widget.language.isEmpty
        ? null
        : CodeHighlight.spans(
            code: source,
            language: widget.language,
            base: code,
            brightness: Theme.of(context).brightness,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // Held at the user's *code* size, out of reach of the UI scale — the
          // two settings are independent, and a code surface that took both
          // would apply the scale twice.
          child: CodeTextScope(
            child: Scrollbar(
              controller: _vertical,
              child: SingleChildScrollView(
                controller: _vertical,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // Long lines run off to the right rather than wrapping: a
                  // wrapped line breaks the one-line-one-number promise the
                  // gutter beside it makes.
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 10, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 12, right: 14),
                          child: Text(
                            [
                              for (var i = 1; i <= lines.length; i++) '$i',
                            ].join('\n'),
                            textAlign: TextAlign.right,
                            style: gutter,
                          ),
                        ),
                        // Only the code is selectable — a copy that came back
                        // with the line numbers in it would have to be cleaned
                        // up by hand before it could be pasted anywhere.
                        SelectionArea(
                          child: coloured == null
                              ? Text(source, style: code)
                              : Text.rich(coloured, style: code),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.truncated) const _TruncatedBar(),
      ],
    );
  }
}

/// Says the file goes on past what's drawn. Pinned under the source rather than
/// appended to it: a note at the end of 2,000 lines is a note nobody reads.
class _TruncatedBar extends StatelessWidget {
  const _TruncatedBar();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppSurface.recess,
        border: Border(top: BorderSide(color: AppPalette.divider)),
      ),
      child: Text(
        'Showing the first $kFilePreviewMaxLines lines. Open the file to read '
        'the rest.',
        style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
      ),
    );
  }
}

/// A quiet centred sentence for a file there is nothing to draw for.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// The file couldn't be read. Shows the reason the system gave rather than a
/// sentence of our own — "Operation not permitted" tells the user what to fix.
class _Failed extends StatelessWidget {
  const _Failed(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: LucideIcons.fileWarning,
    title: 'Could not read this file',
    message: message,
    compact: true,
  );
}
