import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/popover_surface.dart';
import '../../../shared/widgets/scroll_reveal_text.dart';
import '../../../core/age_label.dart';

/// The card's width. Fixed rather than sized to its title: the reveal only
/// means anything against a stable edge, and cards of different widths popping
/// out as the pointer runs down the rail is a lot of movement for a preview.
const double _cardWidth = 236;

/// The gap between the rail's edge and the card.
const double _cardGap = 10;

/// How long the pointer has to settle on a row before the card appears. A
/// tooltip's beat — long enough that crossing the rail to reach something else
/// never trails a card behind the pointer.
const Duration _hoverDelay = Duration(milliseconds: 380);

/// Floats a preview of a chat to the right of its sidebar row while the pointer
/// rests on it: the full title, when it was last touched, and the project (or
/// section) it lives in.
///
/// The rail is narrow, so a chat's title is usually cut off — the row tells you
/// a conversation exists without telling you which one. This is the answer to
/// that, and it's why the title inside is a [ScrollRevealText]: a card that
/// truncated the same title a second time would have been no answer at all.
class ChatHoverPreview extends StatefulWidget {
  const ChatHoverPreview({
    super.key,
    required this.title,
    required this.place,
    required this.placeIcon,
    required this.updatedAt,
    required this.child,
    this.suppressed = false,
  });

  final String title;

  /// Where the chat lives — a project's name, or the section holding the chats
  /// that belong to no project.
  final String place;

  final IconData placeIcon;

  /// When the chat was last touched, rendered as a short age.
  final DateTime updatedAt;

  /// The row this hangs off.
  final Widget child;

  /// Hold the card back — something else is speaking for this row.
  ///
  /// The row's right-click menu opens at the pointer and grows into the same
  /// space this card floats in, so the two would overlap while the pointer is
  /// still, by definition, on the row. The card gives way: a menu is being
  /// answered, a preview is only being read.
  ///
  /// The hover itself is untouched, so dismissing the menu with the pointer
  /// still on the row brings the card back rather than making the row look
  /// spent.
  final bool suppressed;

  @override
  State<ChatHoverPreview> createState() => _ChatHoverPreviewState();
}

class _ChatHoverPreviewState extends State<ChatHoverPreview> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  Timer? _timer;

  /// Stamped when the card opens rather than read during build: an age is only
  /// honest at the moment it's shown, and a row rebuilds for reasons that have
  /// nothing to do with the clock.
  String _age = '';

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onEnter() {
    _timer?.cancel();
    _timer = Timer(_hoverDelay, () {
      if (!mounted || _portal.isShowing) return;
      setState(() {
        _age = ageLabel(widget.updatedAt, DateTime.now());
        _portal.show();
      });
    });
  }

  void _onExit() {
    _timer?.cancel();
    if (!_portal.isShowing) return;
    setState(_portal.hide);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onEnter(),
      onExit: (_) => _onExit(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          // Never a pointer target: the card is a report, and letting it take
          // the hover would mean the row it describes stops being hovered the
          // moment you looked at it.
          overlayChildBuilder: (context) => widget.suppressed
              ? const SizedBox.shrink()
              : Positioned(
                  width: _cardWidth,
                  child: CompositedTransformFollower(
                    link: _link,
                    targetAnchor: Alignment.centerRight,
                    followerAnchor: Alignment.centerLeft,
                    offset: const Offset(_cardGap, 0),
                    child: IgnorePointer(
                      child: _CardEntrance(
                        child: _PreviewCard(
                          title: widget.title,
                          age: _age,
                          place: widget.place,
                          placeIcon: widget.placeIcon,
                        ),
                      ),
                    ),
                  ),
                ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The card arriving: a short fade while it drifts in from the row it belongs
/// to, so it reads as coming *out of* the rail rather than blinking into place.
class _CardEntrance extends StatelessWidget {
  const _CardEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 150),
    curve: Curves.easeOut,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset((1 - t) * -6, 0), child: child),
    ),
    child: child,
  );
}

/// What the card says: the title on top with its age, the place underneath.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.title,
    required this.age,
    required this.place,
    required this.placeIcon,
  });

  final String title;
  final String age;
  final String place;
  final IconData placeIcon;

  @override
  Widget build(BuildContext context) {
    // Mounted in the overlay, out of reach of any watch further up the rail.
    AppTheme.watch(context);
    // textSecondary, not the rail's textFaint: the card is drawn on the menu
    // fill, where faint measures 2.80:1 in dark. Secondary reads 6.00:1 there
    // and 6.21:1 on the light fill.
    final quiet = AppPalette.textSecondary;

    return PopoverSurface(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // Still, and up to two lines: the moving reveal belongs to the
                // row the pointer is on, and a card that also crawled would put
                // the same title in motion twice. Two lines is what lets it be
                // the place the whole name actually fits.
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 12.8,
                    height: 1.3,
                    fontWeight: AppFont.medium,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                age,
                style: TextStyle(color: quiet, fontSize: 11.5, height: 1.45),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Icon(placeIcon, size: 13, color: quiet),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  place,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: quiet, fontSize: 12, height: 1.25),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
