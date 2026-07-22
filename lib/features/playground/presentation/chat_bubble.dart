import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../logic/chat_message.dart';
import 'message_content.dart';
import 'message_plan.dart';
import 'message_sources.dart';

/// How wide running text is allowed to get inside the transcript column.
///
/// The column itself is deliberately wide (1000, in `chat_view.dart`) so tables
/// and code blocks have room. Body copy shouldn't inherit that: a line stops
/// being comfortable past roughly 75–85 characters, which at the app's 15pt
/// body lands near here. Two separate numbers, so widening the column for wide
/// content never drags prose back out with it.
const double proseWidth = 760;

/// One transcript turn — the user's message (accent, right-aligned) or the
/// assistant's reply (surface, left-aligned). Renders text and/or inline media
/// via [MessageContent]. Shared by the Playground dialog and the Chat tab.
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppGlass tokens — follow theme flips. Without this a turn
    // keeps the colours it was first built under: the bubbles are items of a
    // lazy ListView, which holds its built children across a rebuild of the
    // transcript, so a flip left the whole conversation in the old theme's ink —
    // near-invisible white text on the light pane.
    AppTheme.watch(context);
    final isUser = message.role == ChatRole.user;
    if (!isUser) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          // Matches the user bubble's own vertical margin so the gap between
          // any two turns is the same 14px, whoever spoke. The two used to be
          // 10 and 6, which made an assistant→user gap read tighter than a
          // user→assistant one and gave the transcript an uneven rhythm.
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Prose is held to a comfortable measure while the surrounding
              // column stays wide. The cap sits here rather than inside
              // MessageContent on purpose: a table or code block lives *within*
              // a text segment, so capping at the segment level would bind
              // those too — which is exactly why the column was widened to 1000
              // in the first place. gpt_markdown lets wide children overflow
              // this box and scroll, so they still get the full width.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: proseWidth),
                child: MessageContent(
                  text: message.text,
                  media: message.media,
                  color: AppPalette.textPrimary,
                ),
              ),
              if (message.plan.isNotEmpty) ...[
                const SizedBox(height: 12),
                MessagePlan(entries: message.plan),
              ],
              if (message.sources.isNotEmpty) ...[
                const SizedBox(height: 12),
                MessageSources(sources: message.sources),
              ],
            ],
          ),
        ),
      );
    }

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomLeft: const Radius.circular(14),
      bottomRight: const Radius.circular(6),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          // Rule 1: no rim — depth is fill + shadow. The shadow isn't optional
          // dressing here, it's what replaces the border: measured against the
          // pane, `bubbleFill` is only 1.055:1 in light mode (1.187:1 dark),
          // and §2 puts ~1.05 squarely in "effectively invisible". Fill alone
          // would erase this bubble on the light pane.
          color: AppGlass.bubbleFill,
          borderRadius: radius,
          boxShadow: AppGlass.cardShadow,
        ),
        child: MessageContent(
          text: message.text,
          media: message.media,
          color: AppPalette.textPrimary,
        ),
      ),
    );
  }
}

/// A live progress bubble while a media generation streams — percent plus the
/// relay's short status label, with an indeterminate bar until the first update.
class GeneratingBubble extends StatelessWidget {
  const GeneratingBubble({super.key, required this.phase});
  final SendGenerating phase;

  @override
  Widget build(BuildContext context) {
    // Reads AppGlass tokens — follow theme flips.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final pct = (phase.progress * 100).round();
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: AppGlass.bubbleFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppGlass.hair),
          boxShadow: AppGlass.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined, size: 16),
                const SizedBox(width: 8),
                Text('Generating… $pct%', style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 8),
            AppProgressBar(value: phase.progress <= 0 ? null : phase.progress),
          ],
        ),
      ),
    );
  }
}
