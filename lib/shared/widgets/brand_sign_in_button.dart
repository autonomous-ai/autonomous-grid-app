import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_spinner.dart';

/// A `sign in with <vendor>` control in the shape people already trust: white
/// surface, hairline rim, the vendor's own mark, dark label, a soft lift that
/// firms up under the cursor.
///
/// Deliberately not a `FilledButton` in the app accent. Handing an account over
/// to a third party is the one moment the app should look like *their* flow, not
/// ours — an indigo pill reads as one of our buttons, a white one with the mark
/// reads as the official path. Shared by the Google sign-in on the login screen
/// and the ChatGPT sign-in in onboarding, so both stay the same control.
class BrandSignInButton extends StatefulWidget {
  const BrandSignInButton({
    super.key,
    required this.logo,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  /// The vendor's mark, drawn at its own colours — that's what makes the button
  /// recognisable at a glance.
  final Widget logo;
  final String label;
  final VoidCallback onPressed;

  /// The sign-in is under way: the mark gives way to a spinner and the button
  /// stops taking taps, so a second click can't start a second flow.
  final bool busy;

  @override
  State<BrandSignInButton> createState() => _BrandSignInButtonState();
}

class _BrandSignInButtonState extends State<BrandSignInButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Vendor guidance is a white button with dark text on light surfaces; on our
    // dark charcoal we lift to a slightly raised surface so it stays a distinct,
    // tappable pill instead of sinking into the background.
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
                        child: widget.busy ? const AppSpinner() : widget.logo,
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
