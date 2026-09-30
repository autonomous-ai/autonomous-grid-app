/// One turn of a conversation.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_chat_ui/grid_chat_ui.dart';
import 'package:grid_theme/grid_theme.dart';
import 'package:url_launcher/url_launcher.dart';

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
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final mine = line.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: mine
            ? const EdgeInsets.fromLTRB(14, 10, 14, 10)
            : EdgeInsets.zero,
        constraints: BoxConstraints(
          // The assistant's side runs the full width — it is prose, and
          // narrowing it to bubble width costs a line break every sentence.
          maxWidth: mine
              ? MediaQuery.of(context).size.width * 0.82
              : double.infinity,
        ),
        decoration: BoxDecoration(
          // The user's own turn sits on `bubbleFill`, the assistant's on
          // nothing at all — the same asymmetry the desktop transcript uses.
          // Two filled bubbles facing each other is a messaging app; this is a
          // document with one side quoted back.
          color: mine ? AppGlass.bubbleFill : Colors.transparent,
          borderRadius: BorderRadius.circular(AppCard.radius),
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
                  : ChatMarkdown(
                      text: line.text,
                      color: AppPalette.textPrimary,
                      // No SelectionArea around a phone transcript, so the
                      // text selects on its own.
                      selectable: true,
                      onTapLink: _open,
                    ),
            // Under a finished answer only: the one being written would copy
            // half a reply, and the person's own words are theirs already.
            if (!mine && line.index >= 0 && line.text.trim().isNotEmpty)
              _CopyAnswer(line.text),
          ],
        ),
      ),
    );
  }
}

/// Copies an answer, whole — Markdown and all, so a code block pastes as one.
///
/// A button rather than relying on selection alone: selecting a long answer
/// on a phone means dragging handles across several screens of it.
class _CopyAnswer extends StatelessWidget {
  const _CopyAnswer(this.text);

  final String text;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return IconButton(
      tooltip: 'Copy answer',
      onPressed: () => _copy(context),
      iconSize: 16,
      color: AppPalette.textFaint,
      style: IconButton.styleFrom(minimumSize: const Size.square(36)),
      icon: const Icon(Icons.copy_rounded),
    );
  }
}

/// Opens a link from an answer in the phone's browser, never inside the app:
/// an answer's link is somewhere the person chose to go.
void _open(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
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
    AppTheme.watch(context);
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
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
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
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      height: 160,
      width: 220,
      color: AppCard.inset,
      child: child,
    );
  }
}
