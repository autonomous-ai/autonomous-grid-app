/// One conversation, read and answered on the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/chat_watch.dart';
import '../logic/phone_chats.dart';
import 'chat_bubble.dart';
import 'chat_composer.dart';
import 'grid_app_bar.dart';

/// The transcript of one chat, a page at a time, with a box to answer in.
///
/// Stateful for one reason: which page is on screen. The computer cannot send a
/// long conversation in one reply — the relay ends a connection that frames
/// more than 8 MB — so reading back through a chat is walking [_offset]
/// towards zero, and that walk is this screen's own state, not the link's.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({required this.id, required this.title, super.key});

  /// Which conversation.
  final String id;

  /// What it is called, so the bar has something to say before it loads.
  final String title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// Null means the newest page, which is what a chat opens on.
  int? _offset;

  @override
  Widget build(BuildContext context) {
    final request = (id: widget.id, offset: _offset);
    // Watched, not just read. Without this the screen shows whatever the chat
    // looked like when it opened — a message typed at the computer never
    // appears, and the phone looks finished rather than stale.
    //
    // Only while the newest page is on screen: somebody who has paged back into
    // last week does not want the view yanked forward by an answer arriving at
    // the bottom.
    final live = _offset == null
        ? ref.watch(chatWatchProvider(widget.id))
        : (total: 0, streaming: '');
    final transcript = ref.watch(transcriptProvider(request));
    AppTheme.watch(context);
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      appBar: GridAppBar(title: widget.title.isEmpty ? 'Chat' : widget.title),
      body: Column(
        children: [
          Expanded(
            child: transcript.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _TranscriptProblem(
                message: '$error',
                onRetry: () => ref.invalidate(transcriptProvider(request)),
              ),
              data: (page) => _Transcript(
                page: page,
                streaming: live.streaming,
                onEarlier: page.offset > 0
                    ? () => setState(() {
                        _offset = (page.offset - kTurnsPerPage).clamp(
                          0,
                          page.offset,
                        );
                      })
                    : null,
              ),
            ),
          ),
          ChatComposer(widget.id),
        ],
      ),
    );
  }
}

/// How far back one tap of "Earlier messages" goes.
///
/// Matches the page the computer serves (`kMobileChatPageTurns`). It is stated
/// again here rather than sent because the two are allowed to differ: the
/// computer's number bounds what it will put in a frame, this one bounds what
/// one tap asks for.
const int kTurnsPerPage = 40;

/// The turns themselves, newest at the bottom.
///
/// `reverse: true` and the list walked backwards, which is what puts a chat
/// where a chat belongs: **open on the newest message**. Built the other way up
/// — the obvious way — a long conversation opens at whatever was said first and
/// somebody has to scroll a screen's worth of history to reach the answer they
/// came for. It also means new turns land at the anchored end, so an arriving
/// answer does not shove the page around under a thumb.
class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.page,
    required this.streaming,
    required this.onEarlier,
  });

  final ChatTranscript page;

  /// The answer being written right now, or empty. Drawn as a bubble below the
  /// transcript rather than inside it: it is not a saved turn yet, and it is
  /// replaced by the real one the moment the computer writes it down.
  final String streaming;

  final VoidCallback? onEarlier;

  @override
  Widget build(BuildContext context) {
    if (page.lines.isEmpty && streaming.isEmpty) {
      return const _TranscriptEmpty();
    }
    final count = page.lines.length;
    final live = streaming.isEmpty ? 0 : 1;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      // The live bubble sits at index 0 — the bottom, with the list reversed —
      // and the earlier-messages bar at the very end, which is the top.
      itemCount: count + live + 1,
      itemBuilder: (context, index) {
        if (live == 1 && index == 0) {
          return ChatBubble((
            role: 'assistant',
            text: streaming,
            index: -1,
            media: const [],
          ), chatId: page.id);
        }
        final row = index - live;
        return row == count
            ? _EarlierBar(page: page, onTap: onEarlier)
            : ChatBubble(page.lines[count - 1 - row], chatId: page.id);
      },
    );
  }
}

/// Where the reader is in the history, and the way further back.
class _EarlierBar extends StatelessWidget {
  const _EarlierBar({required this.page, required this.onTap});

  final ChatTranscript page;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    if (onTap == null) {
      // The start of the conversation, said plainly — otherwise a reader who
      // has paged all the way back cannot tell whether there is more.
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Center(
          child: Text('Start of this chat', style: theme.textTheme.bodySmall),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: TextButton(
          onPressed: onTap,
          child: Text('Earlier messages (${page.offset} before this)'),
        ),
      ),
    );
  }
}

class _TranscriptEmpty extends StatelessWidget {
  const _TranscriptEmpty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        'Nothing has been said in this chat yet. Send the first message.',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
      ),
    ),
  );
}

class _TranscriptProblem extends StatelessWidget {
  const _TranscriptProblem({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
