import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../playground/logic/chat_message.dart';

/// How wide the rail's hit area is. Wide enough to hold the inset plus a tick at
/// the wave's crest, and a little over — the surplus is grab room, so a user
/// aiming at a 2px line still lands on it.
const double chatMinimapWidth = _railInset + _tickLiftWidth + 6;

/// How far the ticks sit in from the pane's left edge. Flush against it, the rail
/// read as part of the window frame rather than as part of the conversation.
const double _railInset = 10;

/// The gap between one tick and the next. Tight on purpose: the rail reads as a
/// single dense object — a ruler — rather than a handful of marks scattered down
/// the pane, which is what spacing them by transcript position produced.
const double _tickGap = 9;

/// The longest a preview line runs before it's clipped with an ellipsis. Both
/// lines share it, so the popup stays a predictable size whatever it's showing.
const int _maxPreviewLength = 100;

/// One user turn on the rail: which message it is, the question it asked, and the
/// answer that followed.
class MinimapMark {
  const MinimapMark({required this.index, required this.text, this.reply});

  /// Index into the transcript's message list — what a click scrolls to.
  final int index;

  /// The question, clipped to [_maxPreviewLength].
  final String text;

  /// The assistant's answer to it, clipped to [_maxPreviewLength] — or null for a
  /// turn nothing has answered yet (the last one, mid-flight).
  final String? reply;
}

/// The user's turns in [messages], in order, each paired with the reply it drew.
/// Only user messages get a tick: the rail is for finding the question you asked,
/// and marking the assistant's long replies too would leave a solid wall of lines
/// with nothing to aim at — the reply rides along on its question's mark instead.
List<MinimapMark> minimapMarks(List<ChatMessage> messages) => [
  for (var i = 0; i < messages.length; i++)
    if (messages[i].role == ChatRole.user && messages[i].text.trim().isNotEmpty)
      MinimapMark(
        index: i,
        text: _clip(messages[i].text),
        reply: _replyAfter(messages, i),
      ),
];

/// Which of [marks] reads as "you are here" for the message at [currentIndex]:
/// the last mark at or before it, or null when nothing is marked yet.
///
/// The scrolled-to message is usually the assistant's — it has no tick of its
/// own, so the question that prompted it stays lit while you read the answer,
/// which is the turn you're actually in.
int? currentMarkIndex(List<MinimapMark> marks, int? currentIndex) {
  if (currentIndex == null) return null;
  int? found;
  for (var i = 0; i < marks.length; i++) {
    if (marks[i].index > currentIndex) break; // in order: the rest are past it
    found = i;
  }
  return found;
}

/// The assistant's answer to the turn at [index]: the next assistant message
/// before the user speaks again. Null when the turn has no answer yet, so the
/// preview shows the question alone rather than an empty line.
String? _replyAfter(List<ChatMessage> messages, int index) {
  for (var i = index + 1; i < messages.length; i++) {
    if (messages[i].role == ChatRole.user) return null;
    final text = messages[i].text.trim();
    if (text.isNotEmpty) return _clip(text);
  }
  return null;
}

/// [text] as a single line, clipped to [_maxPreviewLength] with an ellipsis. The
/// newlines have to go: a reply is markdown, and its blank lines and bullets would
/// otherwise eat the preview's two lines before any words arrived.
String _clip(String text) {
  final line = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return line.length > _maxPreviewLength
      ? '${line.substring(0, _maxPreviewLength).trimRight()}…'
      : line;
}

/// A slim ruler down the left of the transcript: one tick per question you asked,
/// stacked as an evenly-spaced, vertically-centred cluster. Hovering swells the
/// ticks around the pointer into a wave and previews that question; clicking
/// scrolls to it.
///
/// It's a *table of contents*, not a scrollbar — the real scrollbar is on the
/// right. The ticks are evenly spaced rather than mapped to scroll offsets: what
/// makes a long chat hard to navigate is finding the question you asked, and an
/// evenly-spaced list of them is easier to aim at than marks bunched wherever the
/// turns happened to land.
class ChatMinimap extends StatefulWidget {
  const ChatMinimap({
    super.key,
    required this.marks,
    required this.currentIndex,
    required this.onJumpTo,
  });

  final List<MinimapMark> marks;

  /// The message index the transcript is scrolled to, or null before it's been
  /// measured. The mark at or before it reads as "you are here".
  final int? currentIndex;
  final ValueChanged<int> onJumpTo;

  @override
  State<ChatMinimap> createState() => _ChatMinimapState();
}

class _ChatMinimapState extends State<ChatMinimap> {
  /// Where the pointer is on the rail, in local coordinates, or null when it's
  /// away. The wave is computed from this rather than from a hovered index, so
  /// the ticks swell smoothly as the pointer travels *between* them.
  double? _pointerY;

  /// The mark under the pointer, or null. Drives the preview popup.
  MinimapMark? _hovered;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    if (widget.marks.isEmpty) return const SizedBox(width: chatMinimapWidth);

    return SizedBox(
      width: chatMinimapWidth,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return MouseRegion(
            // Track the pointer across the whole rail, not per-tick: the wave
            // needs a continuous position to fall off from.
            onHover: (event) => _onHover(event.localPosition.dy, height),
            onExit: (_) => setState(() {
              _pointerY = null;
              _hovered = null;
            }),
            child: GestureDetector(
              onTapUp: (_) {
                final mark = _hovered;
                if (mark != null) widget.onJumpTo(mark.index);
              },
              behavior: HitTestBehavior.opaque,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < widget.marks.length; i++)
                    _Tick(
                      centerY: _tickCenter(i, height),
                      // How strongly this tick is caught in the wave, 0..1.
                      lift: _liftFor(_tickCenter(i, height)),
                      current: i == _currentMark,
                    ),
                  if (_hovered != null)
                    _Preview(
                      text: _hovered!.text,
                      reply: _hovered!.reply,
                      top: _previewTop(
                        _tickCenter(widget.marks.indexOf(_hovered!), height),
                        height,
                      ),
                      onTap: () => widget.onJumpTo(_hovered!.index),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  int? get _currentMark => currentMarkIndex(widget.marks, widget.currentIndex);

  void _onHover(double dy, double height) {
    // The nearest tick owns the pointer — with a 9px pitch, requiring a hit on
    // the 2px line itself would make the rail nearly unclickable.
    var nearest = 0;
    var best = double.infinity;
    for (var i = 0; i < widget.marks.length; i++) {
      final d = (dy - _tickCenter(i, height)).abs();
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    setState(() {
      _pointerY = dy;
      // Beyond the wave's reach nothing is really being pointed at, so don't
      // strand a preview open at the far end of the rail.
      _hovered = best <= _waveReach ? widget.marks[nearest] : null;
    });
  }

  /// The centre of tick [i]: the cluster is laid out at a fixed pitch and centred
  /// on the rail, so it grows from the middle out as the conversation gets longer
  /// instead of stretching to fill the pane.
  double _tickCenter(int i, double height) {
    final span = (widget.marks.length - 1) * _tickGap;
    final start = (height - span) / 2;
    return start + i * _tickGap;
  }

  /// How much tick at [centerY] joins the wave: 1 right under the pointer, down
  /// to 0 at [_waveReach] away.
  ///
  /// The falloff is linear, and measured from the pointer itself rather than from
  /// the nearest tick — so the ticks step down by an equal amount each time and
  /// the wave stays symmetric about the pointer as it travels between them. A
  /// raised cosine (the obvious "smooth" choice) varies its own slope across the
  /// reach, which makes the steps visibly uneven: bunched at the crest, stretched
  /// at the edges.
  double _liftFor(double centerY) {
    final y = _pointerY;
    if (y == null) return 0;
    final d = (centerY - y).abs();
    if (d >= _waveReach) return 0;
    return 1 - d / _waveReach;
  }

  /// The popup's top, centred on its tick but kept inside the pane so a preview
  /// near either end isn't clipped by the window.
  double _previewTop(double tickCenter, double height) {
    final centred = tickCenter - _previewHeight / 2;
    return centred.clamp(4.0, math.max(4.0, height - _previewHeight - 4));
  }
}

/// How far the wave reaches from the pointer. About four ticks either side —
/// enough that the swell reads as a wave travelling along the rail rather than
/// one tick lighting up on its own.
const double _waveReach = _tickGap * 4;

const double _tickHeight = 2;

/// Tall enough for the worst case: a two-line question over a two-line reply. A
/// fixed height (rather than one that hugs its text) keeps the card from resizing
/// as the pointer moves between ticks, which reads as flicker.
const double _previewHeight = 92;
const double _previewWidth = 280;

/// The tick's length at rest and at the wave's crest. Resting short and dim keeps
/// the rail quiet next to the text; the crest is what the pointer is aiming at.
const double _tickRestWidth = 10;
const double _tickLiftWidth = 18;

/// The length of the tick marking where the transcript is scrolled to. Between
/// the two above: clearly longer than its neighbours at rest, without claiming to
/// be the crest of a wave nobody is pointing at.
const double _tickCurrentWidth = 14;

/// One mark on the rail.
///
/// [lift] is its place in the hover wave (0 at rest, 1 at the crest) — it drives
/// length, thickness and colour together, so the ticks around the pointer swell
/// as one motion.
///
/// [current] is the separate, quieter job of saying where the transcript is
/// scrolled to: the tick goes ink-dark and full-thickness, and stays that way.
/// It's deliberately un-animated — it changes as a *result* of scrolling, and a
/// mark that eased into place would lag behind the text it's reporting on.
class _Tick extends StatelessWidget {
  const _Tick({
    required this.centerY,
    required this.lift,
    required this.current,
  });

  final double centerY;
  final double lift;
  final bool current;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    // The wave still swells the current tick: the two states stack rather than
    // fight, so pointing at where you are reads the same as pointing anywhere
    // else.
    final width = math.max(
      _tickRestWidth + (_tickLiftWidth - _tickRestWidth) * lift,
      current ? _tickCurrentWidth : 0.0,
    );
    final height = math.max(_tickHeight + lift, current ? _tickHeight + 1 : 0.0);
    return Positioned(
      top: centerY - height / 2,
      // Inset from the rail's left edge. The hit area still starts at 0, so the
      // margin costs no grab room — it only moves the marks.
      left: _railInset,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _color,
          borderRadius: BorderRadius.circular(1),
        ),
        child: SizedBox(width: width),
      ),
    );
  }

  /// Resting grey, fading to [_crestColor] at the wave's crest. The current tick
  /// starts from the primary ink instead — that's what makes it read as marked
  /// while the rail is at rest, without borrowing the colour the wave uses.
  Color get _color {
    final base = current ? AppPalette.textPrimary : AppPalette.textFaint;
    final alpha = current ? 1.0 : 0.55 + 0.45 * lift;
    return Color.lerp(base, _crestColor, lift)!.withValues(alpha: alpha);
  }

  /// What the wave crests to: black on light, white on dark — each theme's own
  /// ink, at full strength.
  ///
  /// Not the indigo accent. The accent is a light-surface colour that went muddy
  /// on the dark pane, and on the light one it made the rail a second point of
  /// colour competing with the composer's own controls. Plain ink is what "lit"
  /// means on either ground, and it keeps the rail as chrome rather than an
  /// action.
  Color get _crestColor =>
      AppTheme.pick(const Color(0xFF000000), const Color(0xFFFFFFFF));
}

/// The hover preview: the question that turn asked over the answer it drew, in a
/// small card beside its tick. Clicking it scrolls there, so the user can aim at
/// the readable card rather than the 2px line.
///
/// The question leads in bold and the reply follows underneath: the question is
/// what the user is scanning for, and the reply is what tells them whether it's
/// the turn they meant.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.text,
    required this.reply,
    required this.top,
    required this.onTap,
  });

  final String text;
  final String? reply;
  final double top;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppGlass tokens — follow theme flips.
    AppTheme.watch(context);
    return Positioned(
      top: top,
      // Sits just clear of the rail, overhanging into the transcript — the rail
      // is far too narrow to hold it.
      left: chatMinimapWidth + 2,
      width: _previewWidth,
      height: _previewHeight,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppGlass.surfaceFill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppGlass.lift),
              boxShadow: AppGlass.cardShadow,
            ),
            // Top-aligned: a one-line question sits at the card's head rather
            // than floating in its middle.
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.32,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
                if (reply != null) ...[
                  const SizedBox(height: 4),
                  Flexible(
                    child: Text(
                      reply!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.32,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
