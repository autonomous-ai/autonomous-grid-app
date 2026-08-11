import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../../shared/code/code_highlight.dart';
import '../../../../shared/external_launch.dart';
import '../../../../shared/markdown/markdown_code_block.dart';
import '../../../../shared/markdown/markdown_style.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/code_text_scope.dart';
import '../../../../shared/widgets/empty_state.dart';
import '../../logic/file_kind.dart';
import '../../logic/file_preview.dart';
import '../../../../shared/widgets/add_to_chat_selection.dart';

/// The file on screen, in whichever form it is worth reading in: Markdown as the
/// document it describes, everything else as source, numbered and coloured.
///
/// Read-only, and both forms are the app's own — the same [CodeHighlight] the
/// transcript and the diff use, and the same markdown stylesheet a chat turn is
/// drawn with. A README opened here should look like the README quoted in an
/// answer, not like a third rendering of the same file in one window.
class FileViewer extends ConsumerWidget {
  const FileViewer({
    super.key,
    required this.path,
    required this.showSource,
    required this.onToggleSource,
    required this.onAddSelection,
  });

  /// The absolute path of the file to show, or null before one is picked.
  final String? path;

  /// Show a Markdown document, or an SVG, as the text it was written in. Means
  /// nothing for any other kind of file, which has only the one form.
  final bool showSource;

  /// Swap between the document and its source.
  ///
  /// Offered on the page rather than in the toolbar, because it is about *this
  /// file* rather than about the panel — and because copying and re-reading are
  /// the same kind of thing, so the two travel together. The toolbar keeps what
  /// acts on the folder: refresh, Finder, the editor.
  final VoidCallback onToggleSource;

  /// A run of text out of this file, on its way to the conversation. Null when
  /// there is no chat to put it in, and then the selection menu is the
  /// platform's own.
  final ValueChanged<String>? onAddSelection;

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
        // Relative images in a README are relative to the file, so the folder
        // it sits in is what turns `./docs/shot.png` into something to draw.
        folder: _folderOf(path),
        markdown: isMarkdownPath(path),
        showSource: showSource,
        onToggleSource: onToggleSource,
        onAddSelection: onAddSelection,
      ),
      AsyncError(:final error) => _Failed('$error'),
      _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
    };
  }
}

/// The folder [path] sits in, with the separator left on — which is the form
/// `flutter_markdown_plus` wants, since it resolves an image by concatenation.
String _folderOf(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? '' : path.substring(0, cut + 1);
}

/// One resolved preview, in whichever of its shapes came back.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.preview,
    required this.language,
    required this.folder,
    required this.markdown,
    required this.showSource,
    required this.onToggleSource,
    required this.onAddSelection,
  });

  final FilePreview preview;

  /// The grammar to colour with, or '' for a file whose extension we have none
  /// for — a `.log`, a `Makefile`, anything the highlighter doesn't know.
  final String language;

  final String folder;

  /// Whether this file is Markdown, which is one of the two kinds with a second
  /// form to switch to. The other — an SVG — is read off the preview itself.
  final bool markdown;

  /// Show the second form: the Markdown behind a document, the markup behind a
  /// picture.
  final bool showSource;

  final VoidCallback onToggleSource;
  final ValueChanged<String>? onAddSelection;

  @override
  Widget build(BuildContext context) {
    // An SVG is a drawing and the markup that draws it, and the switch swaps
    // between them. Decoded here rather than in the provider because the bytes
    // are already in hand: reading the file again to see it the other way would
    // be a second read of a file that hasn't changed.
    final preview = this.preview;
    final shown = switch (preview) {
      FilePreviewImage(:final bytes, vector: true) when showSource =>
        decodeFilePreview(bytes),
      _ => preview,
    };
    final vector = preview is FilePreviewImage && preview.vector;
    final rendered = markdown && !showSource;

    final body = switch (shown) {
      FilePreviewText(:final lines) when lines.isEmpty => const _Note(
        'This file is empty.',
      ),
      FilePreviewText(:final lines, :final truncated) when rendered =>
        _Rendered(
          text: lines.join('\n'),
          folder: folder,
          truncated: truncated,
          onAddSelection: onAddSelection,
        ),
      FilePreviewText(:final lines, :final truncated) => _Source(
        lines: lines,
        truncated: truncated,
        language: language,
        onAddSelection: onAddSelection,
      ),
      FilePreviewImage(:final bytes, :final vector) => _Picture(
        bytes: bytes,
        vector: vector,
      ),
      FilePreviewBinary() => const _Note(
        'This is not a text file, so there is nothing to show. Open it to see '
        'it in the app that handles it.',
      ),
      FilePreviewTooBig(:final bytes) => _Note(
        'This file is ${_megabytes(bytes)} — too big to open here. Open it in '
        'the app that handles it instead.',
      ),
      FilePreviewFailed(:final message) => _Failed(message),
    };

    // Only over a file with two forms and something in it: there is nothing to
    // copy from a binary or an empty file, and nothing to switch to.
    final text = switch (shown) {
      FilePreviewText(:final lines)
          when (markdown || vector) && lines.isNotEmpty =>
        lines.join('\n'),
      FilePreviewImage(:final bytes, vector: true) => utf8.decode(
        bytes,
        allowMalformed: true,
      ),
      _ => null,
    };
    if (text == null) return body;

    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          top: 10,
          right: 12,
          child: _PageActions(
            text: text,
            showSource: showSource,
            vector: vector,
            onToggleSource: onToggleSource,
          ),
        ),
      ],
    );
  }
}

/// Copy, and the switch between the document and its source — floating at the
/// top-right of the page, the way an editor keeps a file's own actions on the
/// file.
///
/// Fixed to the corner rather than scrolling with the text: a switch you have to
/// scroll back up to reach is one you stop using halfway down a long README. The
/// cost is that it sits over the first line, which is why it is small and why it
/// is on a lifted surface — [AppGlass.surfaceFill] with the card shadow under
/// it, so it reads as floating *above* the page rather than as something printed
/// on it (§1: no borders, depth is fill + shadow).
class _PageActions extends StatelessWidget {
  const _PageActions({
    required this.text,
    required this.showSource,
    required this.vector,
    required this.onToggleSource,
  });

  /// The file as it is on disk — what gets copied whichever form is on screen.
  /// Copying the *rendered* document would hand over prose with its markup
  /// silently removed, which is not what anyone means by copying a `.md`.
  final String text;

  final bool showSource;

  /// Whether the two forms are a picture and its markup rather than a document
  /// and its Markdown — the switch is the same, the words for it are not.
  final bool vector;

  final VoidCallback onToggleSource;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(8),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CopyButton(text: text),
            const SizedBox(width: 2),
            AppIconButton(
              icon: showSource
                  ? (vector ? LucideIcons.image300 : LucideIcons.bookOpen300)
                  : LucideIcons.code300,
              size: 15,
              // The tooltip names what the click *does*, not what is on screen:
              // a one-button switch whose icon flips is otherwise a guess.
              tooltip: switch ((showSource, vector)) {
                (true, true) => 'Show the picture',
                (true, false) => 'Show it as a document',
                (false, true) => 'Show the SVG markup',
                (false, false) => 'Show the Markdown source',
              },
              onPressed: onToggleSource,
            ),
          ],
        ),
      ),
    );
  }
}

/// Puts the file on the clipboard, and says so.
///
/// The tick rather than a toast: the answer belongs where the click landed, and
/// a toast for something this small is a notification about a copy. Same
/// two-second confirmation a fenced code block gives in the transcript.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AppIconButton(
      icon: _copied ? LucideIcons.check300 : LucideIcons.copy300,
      size: 15,
      tooltip: _copied ? 'Copied' : 'Copy the file',
      // Green while it holds, so the confirmation reads at a glance rather than
      // asking the user to tell two small grey glyphs apart.
      color: _copied ? AppPalette.online : null,
      hoverColor: _copied ? AppPalette.online : null,
      onPressed: _copy,
    );
  }
}

String _megabytes(int bytes) => '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

/// A file's weight at the scale it happens to be: an icon measured in megabytes
/// reads as 0.0, and a screenshot measured in kilobytes reads as noise.
String _fileSize(int bytes) =>
    bytes < 1 << 20 ? '${(bytes / 1024).round()} KB' : _megabytes(bytes);

/// Markdown as the document it is: headings, lists, tables, and its fences drawn
/// as the same code blocks a chat turn gets.
///
/// The stylesheet is the app's, not the package's — see
/// [buildMarkdownStyleSheet]. What is set here is only what a *file* needs and a
/// chat turn doesn't: where its images live, and a page inset, since a document
/// starting hard against the panel's edge reads as clipped.
class _Rendered extends StatelessWidget {
  const _Rendered({
    required this.text,
    required this.folder,
    required this.truncated,
    required this.onAddSelection,
  });

  final String text;
  final String folder;
  final bool truncated;
  final ValueChanged<String>? onAddSelection;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // Selection comes from here rather than from `selectable: true`, which
          // builds a `SelectableText` per block — a text editor for every
          // paragraph in the document.
          child: AddToChatSelection(
            onAdd: onAddSelection,
            child: Markdown(
              data: text,
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              // What people actually write in a repository: tables, task lists,
              // strikethrough, and bare URLs that should still be links.
              extensionSet: md.ExtensionSet.gitHubFlavored,
              softLineBreak: true,
              selectable: false,
              // Relative image paths resolve against the file's own folder; the
              // package falls back to its error widget when one is missing, so a
              // screenshot that moved doesn't take the document down.
              imageDirectory: folder,
              styleSheet: buildMarkdownStyleSheet(
                context,
                textColor: AppPalette.textPrimary,
              ),
              // Links leave for the browser. A relative link to another file in
              // the project is left alone for now — resolving one means picking
              // it in the tree, which is a navigation this panel doesn't have
              // yet.
              onTapLink: (_, href, _) {
                if (href != null && Uri.tryParse(href)?.hasScheme == true) {
                  openExternalUrl(href);
                }
              },
              builders: {'pre': MarkdownCodeBlockBuilder()},
            ),
          ),
        ),
        if (truncated) const _TruncatedBar(),
      ],
    );
  }
}

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
    required this.onAddSelection,
  });

  final List<String> lines;
  final bool truncated;
  final String language;
  final ValueChanged<String>? onAddSelection;

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
                        AddToChatSelection(
                          onAdd: widget.onAddSelection,
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

/// A picture, on the page rather than described in a sentence.
///
/// Two things it deliberately doesn't do. It never blows an image up past its
/// own pixels ([BoxFit.scaleDown]): a 16-pixel favicon stretched across the
/// panel is a lie about the file, and the size of an asset is usually the thing
/// being checked. And it decodes nothing itself — the engine's image cache
/// holds the frame, so flipping between two files and back is free.
///
/// A format the platform has no codec for (a `.tiff`, an `.icns`) fails to the
/// same sentence a binary gets. That is on purpose: which codecs exist differs
/// per platform, so trying and falling back stays true where a hardcoded list
/// of extensions would quietly rot.
class _Picture extends StatefulWidget {
  const _Picture({required this.bytes, required this.vector});

  final Uint8List bytes;

  /// SVG, which `flutter_svg` draws and the engine's codecs can't.
  final bool vector;

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  /// The frame's own pixel size, once the engine has decoded one. Null for a
  /// vector, which has no pixels until it is drawn, and null for the moment
  /// before the decode lands.
  ({int width, int height})? _pixels;

  ImageStream? _stream;

  late final ImageStreamListener _listener = ImageStreamListener(
    (info, _) {
      if (!mounted) return;
      setState(
        () => _pixels = (width: info.image.width, height: info.image.height),
      );
    },
    // A file that won't decode is already answered on screen by the error
    // builder; the caption simply has nothing to add about it.
    onError: (_, _) {},
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  /// Re-listens whenever the bytes on screen change, which they do without this
  /// widget being rebuilt from scratch: clicking another picture in the tree
  /// reuses this state, and so does the assistant rewriting the open file. The
  /// caption would otherwise keep quoting the previous file's dimensions.
  @override
  void didUpdateWidget(_Picture old) {
    super.didUpdateWidget(old);
    if (widget.bytes != old.bytes) _resolve();
  }

  void _resolve() {
    if (widget.vector) return;
    final stream = MemoryImage(
      widget.bytes,
    ).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final bytes = widget.bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Container(
              // A recessed canvas under the picture, because the picture has no
              // edge of its own: a screenshot with a white background sits on a
              // white page in light mode with nothing to say where it stops.
              // The wash is the one panels already recess with, so it separates
              // (1.07:1 light, 1.12:1 dark) without becoming a frame — §2 keeps
              // the only legal border on a menu's rim.
              decoration: BoxDecoration(
                color: AppSurface.recess,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(12),
              alignment: Alignment.center,
              child: widget.vector
                  ? SvgPicture.memory(bytes, fit: BoxFit.contain)
                  : Image.memory(
                      bytes,
                      fit: BoxFit.scaleDown,
                      // A screenshot shown at a third of its size is all
                      // aliasing at the default quality — this is a viewer, so
                      // the downscale is worth paying for.
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const _Note(
                        "This image is in a format the app can't draw. Open it "
                        'to see it in the app that handles it.',
                      ),
                    ),
            ),
          ),
        ),
        _PictureCaption(pixels: _pixels, bytes: bytes.length),
      ],
    );
  }
}

/// What the picture is, under it: its pixels and its weight.
///
/// Under rather than over, and quiet: it answers the question an asset raises
/// after you have looked at it ("is this the 2× one?"), so it must not be the
/// first thing the eye lands on.
class _PictureCaption extends StatelessWidget {
  const _PictureCaption({required this.pixels, required this.bytes});

  final ({int width, int height})? pixels;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final size = pixels;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        size == null
            ? _fileSize(bytes)
            : '${size.width} × ${size.height} · ${_fileSize(bytes)}',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
      ),
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
