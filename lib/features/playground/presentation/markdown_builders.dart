import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/code_text_scope.dart';
import 'code_highlight.dart';

/// The code block and table renderers a chat turn uses, replacing the defaults
/// that ship with `flutter_markdown_plus`.
///
/// Both defaults are built from stock Material and read as foreign here: the
/// code block fills with `colorScheme.onInverseSurface`, separates with a
/// `Divider`, and labels its copy button with a Material icon; the table draws
/// `TableBorder.all` in `colorScheme.onSurface` — the *text* colour, measured at
/// 18.16:1 against the dark pane, so the grid shouted louder than the data
/// inside it. Neither obeys rule 1 (no borders; depth is fill + shadow).

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

class _MarkdownCodeBlockState extends State<MarkdownCodeBlock> {
  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppCard tokens from inside a lazy transcript — watch here
    // or a theme flip leaves the block on the palette it was first built with.
    AppTheme.watch(context);
    final label = widget.language.trim();

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
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: _CodeText(
                code: widget.code.trimRight(),
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
        ],
      ),
    );
  }
}

/// The code itself: syntax-coloured when the language is known and the block
/// has settled, a single ink otherwise.
///
/// Selectable either way — the transcript is something you copy out of, and a
/// coloured block that can't be selected trades a real capability for a
/// cosmetic one.
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

    if (spans == null) return SelectableText(code, style: base);
    return SelectableText.rich(spans, style: base);
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

/// Renders fenced code blocks (`<pre>`) as [MarkdownCodeBlock].
///
/// `flutter_markdown_plus` has no notion of a fence still being written, so it
/// can't hand us a `closed` flag. The transcript knows,
/// though: [openFence] is computed once per turn from the raw text (see
/// [markdownFenceIsOpen]) and applies to the *last* block in that turn, which is
/// the only one that can still be arriving.
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder({required this.openFence});

  /// True when the turn's text ends inside an unterminated fence.
  final bool openFence;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // <pre><code class="language-dart">…</code></pre>
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final text = code?.textContent ?? element.textContent;
    final classes = code?.attributes['class'] ?? '';
    final language = classes.startsWith('language-')
        ? classes.substring('language-'.length)
        : '';

    return MarkdownCodeBlock(
      language: language,
      code: text,
      closed: !openFence,
    );
  }
}

/// Whether [markdown] ends inside an unterminated ``` fence.
///
/// Counts fence markers at the start of a line: an odd number means the last
/// one never closed, i.e. a code block is still streaming in. Used to withhold
/// the copy action and defer syntax colouring until the block settles.
bool markdownFenceIsOpen(String markdown) {
  final fences = RegExp(
    r'^[ \t]*```',
    multiLine: true,
  ).allMatches(markdown).length;
  return fences.isOdd;
}
