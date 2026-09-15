/// One turn of a conversation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../logic/phone_chats.dart';

/// A message bubble, rendered the way the assistant wrote it.
///
/// The assistant answers in Markdown — headings, lists, fenced code — so the
/// raw text is a wall of asterisks and backticks on a phone screen. The
/// person's own turn is *not* run through Markdown: they typed it, and an
/// underscore they meant literally must not turn half a sentence into italics.
class ChatBubble extends StatelessWidget {
  const ChatBubble(this.line, {super.key});

  /// The turn.
  final ChatLine line;

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
        child: mine
            ? SelectableText(line.text, style: theme.textTheme.bodyMedium)
            : MarkdownBody(
                data: line.text,
                selectable: true,
                styleSheet: _sheet(theme),
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
