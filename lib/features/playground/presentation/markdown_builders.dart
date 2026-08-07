import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../shared/markdown/markdown_code_block.dart';
import '../logic/chart_spec.dart';
import 'message_chart.dart';

/// What a chat turn renders on top of the shared markdown pieces: fences become
/// [MarkdownCodeBlock], and a ```chart fence becomes a drawn chart.
///
/// The block itself lives in `shared/markdown/` — three features render markdown
/// now. What is left here is the part only a transcript has: a fence can still
/// be arriving.

/// Renders fenced code blocks (`<pre>`) as [MarkdownCodeBlock].
///
/// `flutter_markdown_plus` has no notion of a fence still being written, so it
/// can't hand us a `closed` flag. The transcript knows,
/// though: [openFence] is computed once per turn from the raw text (see
/// [markdownFenceIsOpen]) and applies to the *last* block in that turn, which is
/// the only one that can still be arriving.
class CodeBlockBuilder extends MarkdownCodeBlockBuilder {
  CodeBlockBuilder({required this.openFence});

  /// True when the turn's text ends inside an unterminated fence.
  final bool openFence;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final (language, text) = MarkdownCodeBlockBuilder.fenceOf(element);

    // A ```chart block is data, not code: draw it. Only once the fence has
    // closed — half a JSON object parses as nothing, and a chart flickering in
    // and out as it streams is worse than the code block it grew from.
    if (language == 'chart' && !openFence) {
      final spec = ChartSpec.parse(text);
      // Unparseable stays a code block on purpose: showing what actually
      // arrived beats replacing the assistant's output with "invalid chart".
      if (spec != null) return MessageChart(spec: spec);
    }

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
bool markdownFenceIsOpen(String markdown) =>
    _fenceMarker.allMatches(markdown).length.isOdd;

final _fenceMarker = RegExp(r'^[ \t]*```', multiLine: true);
