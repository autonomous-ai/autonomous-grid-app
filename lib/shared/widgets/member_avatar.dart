import 'package:flutter/material.dart';

import '../../features/network/logic/member_display.dart' show memberInitial;
import '../theme/app_theme.dart';

/// A member's circle: their initial, on one of the roster's colours.
///
/// Shared by the three places that draw a roster — the top bar's members panel,
/// the stack beside the Invite button, and the share dialog's people list — so
/// a face is the same shape and weight wherever it appears, and only its size
/// changes with the room it is in.
///
/// It does not pick the colour. `memberAvatarSlots` does, over the whole list at
/// once, because the property worth having is that no two circles *near each
/// other* match — and that is not a question a single circle can answer.
///
/// A circle rather than the rounded square the members panel used to draw. Both
/// shapes were in the app at once (the share dialog was already a circle), and
/// the two read as different *kinds* of thing rather than as the same person in
/// two lists.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.email,
    required this.slot,
    required this.size,
    required this.fontSize,
    this.ring,
  });

  /// The address the letter is taken from — never what the circle prints
  /// beside it, which is the row's business.
  final String email;

  /// Which of [AppPalette.avatarPalette] to fill with, from
  /// `memberAvatarSlots` over the whole list this circle belongs to. Passed in
  /// rather than hashed here because "is this colour already used two rows up?"
  /// is a question only the list can answer.
  final int slot;

  final double size;

  /// Set per call site rather than derived from [size]: a 22px circle in a
  /// 13pt row and a 30px one in a dialog want different optical weights, and a
  /// ratio that suits one leaves the other's glyph too small or too crowded.
  final double fontSize;

  /// The colour of the gap cut around the circle, for a stack where the discs
  /// overlap. Null draws no gap — a circle standing on its own in a list needs
  /// none, and a ring there would read as a border in an app that has none.
  ///
  /// Must be whatever is actually *behind* the stack, since the ring's job is
  /// to look like a hole rather than like an outline.
  final Color? ring;

  /// How thick that gap is. Two logical pixels reads as a cut at every avatar
  /// size the app draws; one disappears at 22.
  static const double ringWidth = 2;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final palette = AppPalette.avatarPalette;
    final disc = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette[slot % palette.length],
      ),
      // A step heavier than the text beside it: white on a saturated fill reads
      // thinner than the same weight on a flat surface.
      child: Text(
        memberInitial(email),
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
    final ring = this.ring;
    if (ring == null) return disc;
    return Container(
      width: size + ringWidth * 2,
      height: size + ringWidth * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
      child: disc,
    );
  }
}
