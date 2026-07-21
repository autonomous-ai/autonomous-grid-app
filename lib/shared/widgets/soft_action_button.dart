import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_spinner.dart';

/// A quiet, tactile action button: white surface, hairline rim, a leading mark,
/// dark label, and a soft lift that firms up under the cursor.
///
/// Where the app's indigo `FilledButton` says "this is the one thing to do on
/// this screen", this says "this is a choice, alongside others" — which is why
/// the sign-in screens and the first-run cards both use it. It also lets a
/// vendor's own mark (Google's G, the ChatGPT glyph) sit at its real colours,
/// so an OAuth button looks like the official path rather than one of ours.
class SoftActionButton extends StatefulWidget {
  const SoftActionButton({
    super.key,
    required this.leading,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  /// The mark before the label — a vendor's logo at its own colours, or a plain
  /// icon. It's what makes the button recognisable at a glance.
  final Widget leading;
  final String label;
  final VoidCallback onPressed;

  /// The action is under way: the mark gives way to a spinner and the button
  /// stops taking taps, so a second click can't start it twice.
  final bool busy;

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
    final base = AppTheme.pick(Colors.white, const Color(0xFF2A2A2A));
    // On hover the surface shifts one quiet step — a hair grey on white, a hair
    // brighter on charcoal — the small "yes, this is clickable" a desktop user
    // expects from a pointer.
    final hoverSurface = AppTheme.pick(
      const Color(0xFFF7F7F6),
      const Color(0xFF333333),
    );
    final hovered = _hovered && !widget.busy;
    final surface = hovered ? hoverSurface : base;
    // The rim firms up on hover — the plain hairline lifts to the more present
    // [AppGlass.lift] rim, so the pill's edge sharpens as it rises.
    final border = hovered ? AppGlass.lift : AppGlass.hair;
    final textColor = AppTheme.pick(
      const Color(0xFF1F1F1F),
      const Color(0xFFF5F5F5),
    );
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
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: Center(
                        child: widget.busy
                            ? const AppSpinner()
                            : widget.leading,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: textColor,
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
