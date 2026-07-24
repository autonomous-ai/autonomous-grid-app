import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../logic/chat_message.dart';
import '../logic/message_media.dart';
import 'markdown_builders.dart';
import 'markdown_style.dart';
import 'media/inline_audio.dart';
import 'media/inline_image.dart';
import 'media/inline_video.dart';
import 'media/local_media_view.dart';
import '../../../shared/external_launch.dart';

/// How wide running text is allowed to get inside the transcript column.
///
/// The column itself is deliberately wide (1000, in `chat_view.dart`) so tables
/// and code blocks have room. Body copy shouldn't inherit that: a line stops
/// being comfortable past roughly 75–85 characters, which at the app's 15pt body
/// lands near here. Two separate numbers, so widening the column for wide
/// content never drags prose back out with it.
const double proseWidth = 760;

/// Splits [markdown] into runs that hold a table and runs that don't.
///
/// The measure has to be applied per *block*, not per message: a reply is
/// usually one text segment holding paragraphs **and** a table, so deciding for
/// the whole segment either squeezes the table or lets the prose run to the full
/// column. Each run is rendered by its own [MarkdownBody], capped or not.
///
/// A table is found by its delimiter row (`|---|:--:|`) — that, not the pipe, is
/// what makes a table a table; pipes show up in ordinary prose and in code.
List<({String text, bool isTable})> _splitByTable(String markdown) {
  final delimiter = RegExp(r'^\s*\|?[\s:-]*-{3,}[\s:|-]*\|');
  final lines = markdown.split('\n');
  final tableLine = List<bool>.filled(lines.length, false);

  for (var i = 1; i < lines.length; i++) {
    if (!delimiter.hasMatch(lines[i])) continue;
    // The delimiter row and the header above it start the table; the body runs
    // on until a line that isn't part of one.
    tableLine[i - 1] = true;
    for (var j = i; j < lines.length && lines[j].contains('|'); j++) {
      tableLine[j] = true;
    }
  }

  final runs = <({String text, bool isTable})>[];
  var start = 0;
  for (var i = 1; i <= lines.length; i++) {
    if (i < lines.length && tableLine[i] == tableLine[start]) continue;
    final text = lines.sublist(start, i).join('\n').trim();
    if (text.isNotEmpty) runs.add((text: text, isTable: tableLine[start]));
    start = i;
  }
  return runs.isEmpty ? [(text: markdown, isTable: false)] : runs;
}

/// Renders a chat message body: markdown text segments via [MarkdownBody], any
/// inline images / videos / audio linked in the text lifted out into their own
/// players, then any generated [media] files (saved locally) below. See
/// [parseMessageSegments] for how the text is split.
class MessageContent extends StatelessWidget {
  const MessageContent({
    super.key,
    required this.text,
    required this.color,
    this.media = const [],
  });

  final String text;
  final Color color;
  final List<ChatMedia> media;

  @override
  Widget build(BuildContext context) {
    final segments = text.isEmpty
        ? const <MessageSegment>[]
        : parseMessageSegments(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _segment(context, segments[i]),
        ],
        for (var i = 0; i < media.length; i++) ...[
          if (i > 0 || segments.isNotEmpty) const SizedBox(height: 8),
          LocalMediaView(media: media[i]),
        ],
      ],
    );
  }

  Widget _segment(BuildContext context, MessageSegment segment) {
    return switch (segment) {
      // One MarkdownBody per run, so prose keeps its measure while a table gets
      // the whole column.
      TextSegment(:final text) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final run in _splitByTable(text))
            if (run.isTable)
              _markdown(context, run.text)
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: proseWidth),
                child: _markdown(context, run.text),
              ),
        ],
      ),
      // A file the agent wrote to disk (a generated image/video): render it from
      // the file, the same way saved outputs are shown, rather than as a link
      // the OS can't open.
      MediaSegment(:final url, :final kind) when isLocalMediaUrl(url) =>
        LocalMediaView(
          media: ChatMedia(path: localMediaPath(url), kind: kind),
        ),
      MediaSegment(:final url, kind: MediaKind.image) => InlineImage(url: url),
      MediaSegment(:final url, kind: MediaKind.video) => InlineVideo(
        source: url,
      ),
      MediaSegment(:final url, kind: MediaKind.audio) => InlineAudio(url: url),
    };
  }

  Widget _markdown(BuildContext context, String text) {
    return MarkdownBody(
      data: text,
      // GitHub Flavored Markdown is what models actually write: tables,
      // strikethrough, task lists, and — the reason a pile of hand-rolled
      // link code could be deleted — autolinks. It handles the cases that
      // used to need patching here: a bare URL becomes a link, while one
      // inside a fence or a `code span` is left exactly as written.
      extensionSet: md.ExtensionSet.gitHubFlavored,
      // CommonMark folds a single newline into a space. Models don't write
      // that way — they use one newline as a line break, and without this a
      // verse or an address collapses into a paragraph.
      softLineBreak: true,
      selectable: true,
      styleSheet: buildMarkdownStyleSheet(context, textColor: color),
      onTapLink: (_, href, _) {
        if (href != null) openExternalUrl(href);
      },
      // The default `pre` is Material chrome with no copy action; see
      // `markdown_builders.dart`.
      builders: {'pre': CodeBlockBuilder(openFence: markdownFenceIsOpen(text))},
    );
  }
}
