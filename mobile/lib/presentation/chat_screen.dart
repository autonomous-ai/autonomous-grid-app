/// One conversation, read and answered on the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/chat_watch.dart';
import '../logic/phone_chats.dart';
import 'chat_composer.dart';
import 'grid_app_bar.dart';
import 'load_states.dart';
import 'transcript_view.dart';

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
        : kQuietTurn;
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
              error: (error, _) => LoadProblem(
                message: '$error',
                onRetry: () => ref.invalidate(transcriptProvider(request)),
              ),
              data: (page) => TranscriptView(
                page: page,
                live: live,
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
