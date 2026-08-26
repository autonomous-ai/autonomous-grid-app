import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_highlight.dart';
import '../copy/plural.dart';
import '../theme/app_theme.dart';
import '../widgets/code_text_scope.dart';

/// The fenced code block the app draws wherever markdown is rendered — a chat
/// turn, a skill's README, a `.md` open in the Files panel.
///
/// `flutter_markdown_plus`'s own is stock Material and reads as foreign here: it
/// fills with `colorScheme.onInverseSurface`, separates with a `Divider`, and
/// labels its copy button with a Material icon. None of that obeys rule 1 (no
/// borders; depth is fill + shadow).

/// A fenced code block: language label, copy action, and the code itself in the
/// app's mono face.
///
/// [closed] is false while a reply is still streaming and the fence hasn't been
/// terminated yet. The block renders either way — waiting for the closing fence
/// would make a finished block pop into existence and shove the answer down —
/// but while it is open the copy action is withheld, since the code is a
/// fragment. It doubles as the app's "this part is still arriving" signal, which
/// is where deferred syntax highlighting would hook in.
class MarkdownCodeBlock extends StatefulWidget {
  const MarkdownCodeBlock({
    super.key,
    required this.language,
    required this.code,
    required this.closed,
  });

  final String language;
  final String code;
  final bool closed;

  @override
  State<MarkdownCodeBlock> createState() => _MarkdownCodeBlockState();
}

/// Past this many lines a block is folded down to [_previewLines].
///
/// Measured against what the transcript is for: a dozen lines is something you
/// read, and a hundred is something you scroll past to find the sentence after
/// it. A quoted selection out of the Files panel or a terminal is routinely a
/// whole file, and it arrived in the conversation as a *reference*, not as the
/// thing the user wanted to read again.
///
/// The gap between the two numbers is deliberate: folding a 20-line block to 12
/// would hide eight lines and spend a row of chrome saying so.
const int _collapseOver = 18;
const int _previewLines = 12;

class _MarkdownCodeBlockState extends State<MarkdownCodeBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens from inside a lazy transcript — watch here
    // or a theme flip leaves the block on the palette it was first built with.
    AppTheme.watch(context);
    final label = widget.language.trim();
    final code = widget.code.trimRight();

    // Only a block that has settled. A fence still streaming grows by the line,
    // and the lines worth watching are the newest ones — folding it would hide
    // exactly what the user is waiting for, and re-measure the whole string on
    // every chunk to do it.
    final lines = widget.closed ? '\n'.allMatches(code).length + 1 : 0;
    final foldable = lines > _collapseOver;
    final folded = foldable && !_expanded;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        // The recessed surface: a code block is a well inside the answer, not a
        // card floating above it.
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label.isEmpty ? 'code' : label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: AppFont.medium,
                      color: AppPalette.textFaint,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                // No copy action until the fence closes: mid-stream the block
                // holds a fragment, and copying half a function is almost
                // always a mistake rather than a choice.
                if (widget.closed)
                  _CopyButton(code: widget.code)
                else
                  Text(
                    'writing…',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: AppFont.medium,
                      color: AppPalette.textFaint,
                    ),
                  ),
              ],
            ),
          ),
          // A hairline, not a Divider: the app's divider token is the quiet
          // separator, and Material's default is a full-strength rule.
          Container(height: 1, color: AppPalette.divider),
          // Only the code takes the code size — the language label and the copy
          // action above are chrome, and they stay on the UI scale with the rest
          // of the transcript.
          CodeTextScope(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // Less room under the code when a bar follows it: the bar brings
              // its own, and two paddings stacked read as a gap in the block.
              padding: EdgeInsets.fromLTRB(14, 12, 14, foldable ? 6 : 14),
              child: _CodeText(
                // Whole lines only — a fold that cut mid-line would need a
                // gradient to explain itself, and would still leave the reader
                // guessing whether the line ended there.
                code: folded ? _firstLines(code, _previewLines) : code,
                language: label,
                // Colour only settles once the fence closes. Highlighting a
                // fragment costs a full re-tokenise per streamed chunk, and the
                // colours churn as the parser guesses at half-written syntax —
                // so mid-stream the block stays plain, exactly as the web chat
                // UIs do it.
                highlight: widget.closed,
              ),
            ),
          ),
          if (foldable) ...[
            // The same hairline as under the header, so the block reads as
            // chrome / code / chrome rather than leaving the bar looking like a
            // last line of output.
            Container(height: 1, color: AppPalette.divider),
            _FoldBar(
              folded: folded,
              lines: lines,
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ],
      ),
    );
  }
}

/// The first [count] lines of [code], without the trailing newline.
String _firstLines(String code, int count) {
  var cut = -1;
  for (var i = 0; i < count; i++) {
    final next = code.indexOf('\n', cut + 1);
    if (next < 0) return code;
    cut = next;
  }
  return code.substring(0, cut);
}

/// The row under a folded block: how much is being held back, and the way to
/// see it.
///
/// Full width and part of the block rather than a button floating over the last
/// line: it is the block's own footer, and something laid over the code would
/// cover the line the reader is trying to finish.
class _FoldBar extends StatefulWidget {
  const _FoldBar({
    required this.folded,
    required this.lines,
    required this.onPressed,
  });

  final bool folded;
  final int lines;
  final VoidCallback onPressed;

  @override
  State<_FoldBar> createState() => _FoldBarState();
}

class _FoldBarState extends State<_FoldBar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Says the size of what is hidden, not "Show more": a reader deciding
    // whether to open a block wants to know whether it is eight more lines or
    // eight hundred.
    final label = widget.folded
        ? 'Show all ${widget.lines} ${plural(widget.lines, 'line')}'
        : 'Show less';
    final ink = _hovered ? AppPalette.textPrimary : AppPalette.textSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onPressed,
        onHover: (value) => setState(() => _hovered = value),
        hoverColor: AppSurface.hoverFill,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 14, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.folded
                    ? LucideIcons.chevronDown300
                    : LucideIcons.chevronUp300,
                size: 14,
                color: ink,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: AppFont.medium,
                  color: ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The code itself: syntax-coloured when the language is known and the block
/// has settled, a single ink otherwise.
///
/// Selectable either way — the transcript is something you copy out of, and a
/// coloured block that can't be selected trades a real capability for a
/// cosmetic one. That comes from the message's enclosing `SelectionArea` now
/// rather than from a `SelectableText` per block: a block is a paragraph, not a
/// text editor, and a reply full of them was building a text editor for each.
class _CodeText extends StatelessWidget {
  const _CodeText({
    required this.code,
    required this.language,
    required this.highlight,
  });

  final String code;
  final String language;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final brightness = AppTheme.watch(context);
    final base = AppFont.codeStyle(color: AppPalette.textPrimary, height: 1.5);

    final spans = highlight
        ? CodeHighlight.spans(
            code: code,
            language: language,
            base: base,
            brightness: brightness,
          )
        : null;

    if (spans == null) return Text(code, style: base);
    return Text.rich(spans, style: base);
  }
}

/// Copy-to-clipboard for a code block, confirming in place.
///
/// The confirmation lives on the button rather than in a toast: the toast layer
/// is for things that happen away from the pointer, and a block halfway up a
/// long transcript shouldn't send feedback to the corner of the window.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});

  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  bool _hovered = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Climbs to textPrimary under the pointer, like every other icon action in
    // the app — an affordance that stays dim while you aim at it reads as decor.
    final ink = _copied
        ? AppPalette.online
        : _hovered
        ? AppPalette.textPrimary
        : AppPalette.textFaint;

    return Semantics(
      button: true,
      label: 'Copy code',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _copy,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: _hovered ? AppSurface.hoverFill : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _copied ? LucideIcons.check300 : LucideIcons.copy300,
                  size: 13,
                  color: ink,
                ),
                const SizedBox(width: 5),
                Text(
                  _copied ? 'Copied' : 'Copy',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: AppFont.medium,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders every fenced block in a document as a [MarkdownCodeBlock].
///
/// The plain case, for markdown that is already whole — a file on disk, a
/// skill's README. A transcript subclasses the parsing here and adds what only
/// a stream has: a fence that hasn't closed yet, and the `chart` language.
class MarkdownCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final (language, code) = fenceOf(element);
    return MarkdownCodeBlock(language: language, code: code, closed: true);
  }

  /// The language and the text of a `<pre><code class="language-x">` element —
  /// the shape `flutter_markdown_plus` hands a fence over in.
  static (String language, String code) fenceOf(md.Element element) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final classes = code?.attributes['class'] ?? '';
    return (
      classes.startsWith('language-')
          ? classes.substring('language-'.length)
          : '',
      code?.textContent ?? element.textContent,
    );
  }
}
