/// One turn of a conversation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_chats.dart';
import '../logic/phone_media.dart';

/// A message bubble, rendered the way the assistant wrote it.
///
/// The assistant answers in Markdown — headings, lists, fenced code — so the
/// raw text is a wall of asterisks and backticks on a phone screen. The
/// person's own turn is *not* run through Markdown: they typed it, and an
/// underscore they meant literally must not turn half a sentence into italics.
class ChatBubble extends StatelessWidget {
  const ChatBubble(this.line, {required this.chatId, super.key});

  /// The turn.
  final ChatLine line;

  /// Which conversation it belongs to — needed to ask for its pictures.
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = line.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: mine
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, item) in line.media.indexed)
              _Attachment(
                chatId: chatId,
                message: line.index,
                media: index,
                item: item,
              ),
            if (line.text.trim().isNotEmpty)
              mine
                  ? SelectableText(line.text, style: theme.textTheme.bodyMedium)
                  : MarkdownBody(
                      data: line.text,
                      selectable: true,
                      styleSheet: _sheet(theme),
                    ),
          ],
        ),
      ),
    );
  }
}

/// Markdown styled to this app rather than to the package's defaults.
///
/// Two things matter on a phone and are wrong out of the box: code has to be
/// able to scroll sideways instead of forcing the whole page wide, and the
/// block quote and code backgrounds have to come from the theme or they are
/// invisible in dark mode.
MarkdownStyleSheet _sheet(ThemeData theme) {
  final mono = theme.textTheme.bodySmall?.copyWith(
    fontFamily: 'Menlo',
    fontFamilyFallback: const ['Courier', 'monospace'],
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    code: mono,
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
    ),
    blockquoteDecoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: theme.dividerColor)),
    ),
  );
}

/// One picture on a turn, fetched when it is first drawn.
///
/// Only pictures are shown. Anything else is named instead: the phone cannot
/// open a `.docx`, and downloading megabytes to render a file icon over it
/// would be paid for by whoever is on a mobile connection.
class _Attachment extends ConsumerWidget {
  const _Attachment({
    required this.chatId,
    required this.message,
    required this.media,
    required this.item,
  });

  final String chatId;
  final int message;
  final int media;
  final ChatMediaRef item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (item.kind != 'image') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 16,
              color: theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                item.name,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    final bytes = ref.watch(
      chatMediaProvider((chatId: chatId, message: message, media: media)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: bytes.when(
          // A fixed box while it loads, so the transcript does not jump when a
          // picture lands under the thumb that is scrolling it.
          loading: () => _Placeholder(
            child: const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: (error, _) => _Placeholder(
            child: Center(
              child: Text(
                "Couldn't load this picture.",
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          data: Image.memory,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    height: 160,
    width: 220,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: child,
  );
}
