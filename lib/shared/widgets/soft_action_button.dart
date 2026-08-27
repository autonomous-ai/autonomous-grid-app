import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_spinner.dart';

/// A tactile action button at hero size: a soft lift that firms up under the
/// cursor, a leading mark when there is one, and either a quiet white surface or
/// the accent fill.
///
/// Quiet by default — where the app's `FilledButton` says "this is the one thing
/// to do on this screen", the plain form says "this is a choice, alongside
/// others", which is what the first-run cards want. It also lets a vendor's own
/// mark (Google's G, the ChatGPT glyph) sit at its real colours, so an OAuth
/// button looks like the official path rather than one of ours.
///
/// [filled] is the other weight, and exists because `FilledButton` is 32px tall:
/// right for a control in a row, far too small for the single call to action on
/// a full-window screen with nothing else to press. The size lives here rather
/// than in `AppControl` because hero geometry is this widget's whole reason to
/// exist — a caller that reached for `FilledButton` and passed a height would be
/// putting a number at a call site (§5).
class SoftActionButton extends StatefulWidget {
  const SoftActionButton({
    super.key,
    required this.label,
    this.leading,
    required this.onPressed,
    this.busy = false,
    this.compact = false,
    this.stretch = false,
    this.filled = false,
  });

  /// The mark before the label — a vendor's logo at its own colours, or a
  /// plain icon. It's what makes the button recognisable at a glance.
  ///
  /// Null for a button carrying no mark. A [filled] one usually should: a
  /// multicolour vendor logo on an accent fill is the one foreign element on
  /// the screen, and Google's own brand rules ask for their G on white,
  /// neutral grey, black or Google Blue — not on a palette of ours.
  final Widget? leading;
  final String label;
  final VoidCallback onPressed;

  /// The action is under way: the mark gives way to a spinner and the button
  /// stops taking taps, so a second click can't start it twice.
  final bool busy;

  /// A shorter pill for a button sitting inside a card. Full height is for a
  /// screen's single call to action (the sign-in screens), where the button is
  /// the only thing to press.
  final bool compact;

  /// Fill the width the caller hands down instead of hugging the label.
  ///
  /// For a button that has to line up with something above it. Off by
  /// default because a pill that hugs its label is the macOS shape, and a
  /// button stretched across a pane with nothing to agree with reads as a
  /// web form's submit.
  final bool stretch;

  /// Wear the accent fill instead of the quiet white surface.
  ///
  /// For the one action a screen exists to get: it has to out-rank
  /// everything around it, and on a page that is otherwise all argument a
  /// white pill on a white card is not a call to action, it is a footnote.
  final bool filled;

  @override
  State<SoftActionButton> createState() => _SoftActionButtonState();
}

class _SoftActionButtonState extends State<SoftActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // White with dark text on light surfaces (which is also what the OAuth
    // vendors ask for); on our dark charcoal we lift to a slightly raised
    // surface so it stays a distinct, tappable pill instead of sinking in.
    final base = widget.filled
        ? AppPalette.accent
        : AppTheme.pick(Colors.white, const Color(0xFF2A2A2A));
    // On hover the surface shifts one quiet step — a hair grey on white, a hair
    // brighter on charcoal — the small "yes, this is clickable" a desktop user
    // expects from a pointer.
    final hoverSurface = widget.filled
        ? AppPalette.accentHover
        : AppTheme.pick(const Color(0xFFF7F7F6), const Color(0xFF333333));
    final hovered = _hovered && !widget.busy;
    final surface = hovered ? hoverSurface : base;
    // The rim firms up on hover — the plain hairline lifts to the more present
    // [AppGlass.lift] rim, so the pill's edge sharpens as it rises.
    // A filled pill draws its own edge with its fill; a rim over the accent
    // only muddies it.
    final border = widget.filled
        ? Colors.transparent
        : (hovered ? AppGlass.lift : AppGlass.hair);
    final textColor = widget.filled
        ? Colors.white
        : AppTheme.pick(const Color(0xFF1F1F1F), const Color(0xFFF5F5F5));
    final radius = BorderRadius.circular(12);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // Rise a single pixel to meet the cursor — enough to feel physical, small
      // enough never to look like the button jumped.
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        offset: hovered ? const Offset(0, -0.021) : Offset.zero,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: radius,
            // A touch more lift on hover, so the pill rises to meet the cursor.
            boxShadow: hovered ? AppGlass.shadow : AppGlass.cardShadow,
          ),
          child: Material(
            color: surface,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.busy ? null : widget.onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                height: widget.compact ? 40 : 48,
                padding: EdgeInsets.symmetric(
                  horizontal: widget.compact ? 16 : 22,
                ),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: border),
                ),
                child: Row(
                  mainAxisSize: widget.stretch
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.busy || widget.leading != null) ...[
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: Center(
                          child: widget.busy
                              ? (widget.filled
                                    ? const AppSpinner.onAccent()
                                    : const AppSpinner())
                              : widget.leading,
                        ),
                      ),
                      SizedBox(width: widget.compact ? 9 : 12),
                    ],
                    // A label, not the page's text — see `unselectableLabel`,
                    // which says the same for every Material button. This one
                    // is hand-built, so no `ButtonStyle` reaches it.
                    SelectionContainer.disabled(
                      child: Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: widget.compact ? 14 : 15,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
