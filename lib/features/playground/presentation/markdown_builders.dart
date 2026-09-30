import 'package:flutter/material.dart';
import 'package:grid_chat_ui/grid_chat_ui.dart';
import 'package:markdown/markdown.dart' as md;

import '../logic/chart_spec.dart';
import 'message_chart.dart';

/// What a chat turn renders on top of the shared markdown pieces: fences become
/// [MarkdownCodeBlock], and a ```chart fence becomes a drawn chart.
///
/// The block itself lives in `packages/grid_chat_ui`, shared with the phone.
/// What is left here is the part only the desktop draws: a chart.

/// Renders fenced code blocks (`<pre>`) as [MarkdownCodeBlock].
///
/// `flutter_markdown_plus` has no notion of a fence still being written, so it
/// can't hand us a `closed` flag. The transcript knows, though: [closed] is
/// computed once per turn from the raw text (see [markdownFenceIsOpen]) and
/// applies to the *last* block in that turn, the only one still arriving.
class CodeBlockBuilder extends MarkdownCodeBlockBuilder {
  CodeBlockBuilder({required super.closed});

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
    if (language == 'chart' && closed) {
      final spec = ChartSpec.parse(text);
      // Unparseable stays a code block on purpose: showing what actually
      // arrived beats replacing the assistant's output with "invalid chart".
      if (spec != null) return MessageChart(spec: spec);
    }

    return MarkdownCodeBlock(language: language, code: text, closed: closed);
  }
}
