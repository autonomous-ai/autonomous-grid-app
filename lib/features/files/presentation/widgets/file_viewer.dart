import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../../../../shared/widgets/labeled_field.dart';
import '../../logic/file_kind.dart';
import '../../logic/file_preview.dart';
import 'files_menu_row.dart';

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

  /// Show Markdown as the text it was written in. Means nothing for any other
  /// kind of file, which has only the one form.
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

    final markdown = isMarkdownPath(path);
    return switch (ref.watch(filePreviewProvider(path))) {
      AsyncData(:final value) => _Preview(
        preview: value,
        language: languageForPath(path),
        // Relative images in a README are relative to the file, so the folder
        // it sits in is what turns `./docs/shot.png` into something to draw.
        folder: _folderOf(path),
        markdown: markdown,
        rendered: markdown && !showSource,
        onToggleSource: onToggleSource,
        onAddSelection: onAddSelection,
      ),
      AsyncError(:final error) => _Failed('$error'),
      _ => const Center(child: AppSpinner(size: SpinnerSize.medium)),
    };
  }
}

/// How far the pointer must travel before a press counts as picking text out.
///
/// A click *inside* a selection is how you dismiss it, and a click that landed
/// a pixel off centre must not be read as a fresh drag — that would pop the menu
/// over a selection the user was in the middle of throwing away.
const double _dragSlop = 6;

/// Selectable text that offers **Add to Chat** the moment a selection is made.
///
/// Two ways in, because they answer different habits:
///
///  - **Let go of the drag** and the app's own one-item menu appears where the
///    pointer stopped. This is the affordance the feature is for; macOS shows
///    nothing after a mouse drag by design (see `_handleMouseDragEnd` in
///    `selectable_region.dart`), and `SelectableRegion` keeps its `_showToolbar`
///    private, so the menu here is the app's rather than the platform's.
///  - **Right-click** and the platform's own strip appears, with Copy and Select
///    All where the user expects them and *Add to Chat* appended. Replacing that
///    one would mean re-implementing two behaviours nobody asked to change.
///
/// The selected text is kept in a plain field rather than in state: it changes
/// on every tick of a drag, and rebuilding a two-thousand-line file to remember
/// a string no menu has asked for yet is work for nothing.
class _AddToChatSelection extends StatefulWidget {
  const _AddToChatSelection({required this.onAdd, required this.child});

  /// Null when the panel has nowhere to put a selection, and then there is no
  /// menu on release and the right-click one is exactly the platform's own.
  final ValueChanged<String>? onAdd;

  final Widget child;

  @override
  State<_AddToChatSelection> createState() => _AddToChatSelectionState();
}

class _AddToChatSelectionState extends State<_AddToChatSelection> {
  final _menu = MenuController();
  String? _selected;

  /// Where the *left* button went down, so a release can tell a drag from a
  /// click. Null for any other button: a right-click has its own menu, and a
  /// right-drag must not open a second one over it.
  Offset? _pressed;

  String? get _addable {
    final text = _selected;
    if (widget.onAdd == null) return null;
    return text != null && text.trim().isNotEmpty ? text : null;
  }

  void _down(PointerDownEvent event) {
    // A press anywhere puts the last menu away — including the press that
    // starts the next selection, which would otherwise leave two on screen.
    if (_menu.isOpen) _menu.close();
    _pressed = event.buttons == kPrimaryButton ? event.localPosition : null;
  }

  void _up(PointerUpEvent event) {
    final from = _pressed;
    _pressed = null;
    if (from == null) return;
    if ((event.localPosition - from).distance < _dragSlop) return;

    // After the frame: the selection is finalised on drag end, and asking for it
    // in the same event that ended the drag reads the *previous* answer.
    final at = event.localPosition;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _addable == null || _menu.isOpen) return;
      // Just below the pointer, so the menu doesn't land on the last words of
      // what was selected.
      _menu.open(position: at + const Offset(4, 8));
    });
  }

  void _add() {
    final text = _addable;
    _menu.close();
    if (text != null) widget.onAdd!(text);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_selectionMenuWidth, 0)),
      ),
      menuChildren: [
        SizedBox(
          width: _selectionMenuWidth,
          child: FilesMenuRow(
            icon: LucideIcons.messageSquarePlus300,
            label: 'Add to Chat',
            onPressed: _add,
          ),
        ),
      ],
      builder: (context, controller, child) => Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        child: SelectionArea(
          onSelectionChanged: (content) => _selected = content?.plainText,
          contextMenuBuilder: (context, selection) {
            final text = _addable;
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: selection.contextMenuAnchors,
              buttonItems: [
                ...selection.contextMenuButtonItems,
                if (text != null)
                  ContextMenuButtonItem(
                    label: 'Add to Chat',
                    onPressed: () {
                      // The strip goes first: the selection stays highlighted so
                      // the user can see what they just sent, but a menu left
                      // standing over it would hide the chip appearing below.
                      selection.hideToolbar();
                      widget.onAdd!(text);
                    },
                  ),
              ],
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

const double _selectionMenuWidth = 168;

/// The folder [path] sits in, with the separator left on — which is the form
/// `flutter_markdown_plus` wants, since it resolves an image by concatenation.
String _folderOf(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? '' : path.substring(0, cut + 1);
}

/// One resolved preview, in whichever of its four shapes came back.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.preview,
    required this.language,
    required this.folder,
    required this.markdown,
    required this.rendered,
    required this.onToggleSource,
    required this.onAddSelection,
  });

  final FilePreview preview;

  /// The grammar to colour with, or '' for a file whose extension we have none
  /// for — a `.log`, a `Makefile`, anything the highlighter doesn't know.
  final String language;

  final String folder;

  /// Whether this file has two forms at all.
  final bool markdown;

  /// Draw the text as Markdown rather than as source.
  final bool rendered;

  final VoidCallback onToggleSource;
  final ValueChanged<String>? onAddSelection;

  @override
  Widget build(BuildContext context) {
    final body = switch (preview) {
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
      FilePreviewBinary() => const _Note(
        'This is not a text file, so there is nothing to show. Open it to see '
        'it in the app that handles it.',
      ),
      FilePreviewTooBig(:final bytes) => _Note(
        'This file is ${_megabytes(bytes)} — too big to read here. Open it in '
        'your editor instead.',
      ),
      FilePreviewFailed(:final message) => _Failed(message),
    };

    // Only over a document with something in it: there is nothing to copy from
    // a binary or an empty file, and nothing to switch to.
    final text = switch (preview) {
      FilePreviewText(:final lines) when markdown && lines.isNotEmpty =>
        lines.join('\n'),
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
            showSource: !rendered,
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
    required this.onToggleSource,
  });

  /// The file as it is on disk — what gets copied whichever form is on screen.
  /// Copying the *rendered* document would hand over prose with its markup
  /// silently removed, which is not what anyone means by copying a `.md`.
  final String text;

  final bool showSource;
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
              icon: showSource ? LucideIcons.bookOpen300 : LucideIcons.code300,
              size: 15,
              // The tooltip names what the click *does*, not what is on screen:
              // a one-button switch whose icon flips is otherwise a guess.
              tooltip: showSource
                  ? 'Show it as a document'
                  : 'Show the Markdown source',
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
          child: _AddToChatSelection(
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
                        _AddToChatSelection(
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
