/// One run of an answer's Markdown, drawn the way Grid draws it everywhere.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_code_block.dart';
import 'markdown_style.dart';

/// Markdown as a chat answer is written: GitHub-flavoured, one newline a line
/// break, fences drawn as [MarkdownCodeBlock].
///
/// The three choices below are why this is a widget and not a stylesheet: each
/// is a thing a model's answer gets wrong without, and a surface that set two
/// of them drew the same answer differently from the one that set three.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown({
    required this.text,
    required this.color,
    this.selectable = false,
    this.onTapLink,
    this.codeBlocks,
    super.key,
  });

  /// The Markdown.
  final String text;

  /// The ink — the answer's, or the user's inside their own bubble.
  final Color color;

  /// Whether the text selects on its own. Off where an enclosing
  /// `SelectionArea` already does it, which selects across paragraphs and
  /// builds no editor per paragraph; on where there is none.
  final bool selectable;

  /// Opening a link. Null draws links that do nothing when tapped.
  final void Function(String href)? onTapLink;

  /// How fences are drawn, when a surface has more to say than a code block —
  /// the desktop draws a ```chart fence as a chart. Null draws every fence as
  /// a [MarkdownCodeBlock], still copyable only once it has closed.
  final MarkdownElementBuilder? codeBlocks;

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    // GitHub Flavored Markdown is what models actually write: tables,
    // strikethrough, task lists and autolinks — a bare URL becomes a link,
    // while one inside a fence or a `code span` is left exactly as written.
    extensionSet: md.ExtensionSet.gitHubFlavored,
    // CommonMark folds a single newline into a space. Models use one newline
    // as a line break, and without this an address collapses into a paragraph.
    softLineBreak: true,
    selectable: selectable,
    styleSheet: buildMarkdownStyleSheet(context, textColor: color),
    onTapLink: (_, href, _) {
      if (href != null) onTapLink?.call(href);
    },
    builders: {
      'pre':
          codeBlocks ??
          MarkdownCodeBlockBuilder(closed: !markdownFenceIsOpen(text)),
    },
  );
}

/// Whether [markdown] ends inside an unterminated ``` fence.
///
/// Counts fence markers at the start of a line: an odd number means the last
/// one never closed, i.e. a code block is still streaming in. Used to withhold
/// the copy action and defer syntax colouring until the block settles.
bool markdownFenceIsOpen(String markdown) =>
    _fenceMarker.allMatches(markdown).length.isOdd;

final _fenceMarker = RegExp(r'^[ \t]*```', multiLine: true);
