/// The scrolling half of a chat: the saved turns, the one being written, and
/// the way back through the history.
library;

import 'package:flutter/material.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chats.dart';
import 'chat_bubble.dart';
import 'live_turn_view.dart';
import 'load_states.dart';

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
class TranscriptView extends StatefulWidget {
  const TranscriptView({
    required this.page,
    required this.live,
    required this.onEarlier,
    super.key,
  });

  /// The saved turns on screen.
  final ChatTranscript page;

  /// What the computer is doing in this chat right now. Drawn below the
  /// transcript rather than inside it: it is not a saved turn yet, and it is
  /// replaced by the real one the moment the computer writes it down.
  final MobileLiveTurn live;

  /// Walks one page further back, or null at the start of the chat.
  final VoidCallback? onEarlier;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final _scroll = ScrollController();

  /// Whether the reader has scrolled far enough up that the newest message is
  /// off screen — when the way back down is worth a button.
  bool _up = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Reversed, so the newest message is at offset zero.
    final up = _scroll.offset > _kShowJumpAfter;
    if (up != _up) setState(() => _up = up);
  }

  void _toNewest() =>
      _scroll.animateTo(0, duration: AppMotion.fold, curve: AppMotion.curve);

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final live = widget.live;
    if (page.lines.isEmpty && !live.busy && live.streaming.isEmpty) {
      return const EmptyNote(
        'Nothing has been said in this chat yet. Send the first message.',
      );
    }
    final count = page.lines.length;
    final working = live.busy || live.streaming.isNotEmpty ? 1 : 0;
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          reverse: true,
          // A drag through the transcript is somebody reading, not typing —
          // the keyboard goes, and gives them back half the screen.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          // The live turn sits at index 0 — the bottom, with the list
          // reversed — and the earlier-messages bar at the very end, the top.
          itemCount: count + working + 1,
          itemBuilder: (context, index) {
            if (working == 1 && index == 0) {
              return LiveTurnView(chatId: page.id, live: live);
            }
            final row = index - working;
            return row == count
                ? _EarlierBar(page: page, onTap: widget.onEarlier)
                : ChatBubble(page.lines[count - 1 - row], chatId: page.id);
          },
        ),
        if (_up)
          Positioned(
            right: 16,
            bottom: 12,
            child: _JumpToNewest(onTap: _toNewest),
          ),
      ],
    );
  }
}

/// How far up the reader has to be before the way back down is offered.
const double _kShowJumpAfter = 400;

/// The small round button that scrolls back to the newest message.
class _JumpToNewest extends StatelessWidget {
  const _JumpToNewest({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return IconButton.filledTonal(
      tooltip: 'Newest message',
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: AppPalette.cardBg,
        foregroundColor: AppPalette.textSecondary,
        minimumSize: const Size.square(40),
        side: BorderSide(color: AppGlass.hair),
      ),
      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
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
