import 'package:flutter/material.dart';

import '../../../../shared/layouts/onboarding_backdrop.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/soft_action_button.dart';
import '../../logic/grid_growth.dart';
import '../google_logo.dart';
import 'capacity_rail.dart';
import 'grid_growth_band.dart';

/// The front door: what a grid is *for*, shown rather than claimed, with the one
/// thing to do underneath it.
///
/// This used to be two screens — a card asking for a sign-in, and a one-time
/// welcome shown at the *end* of setup, after the user had already spent their
/// curiosity on three questions. The argument for the product was landing on
/// someone who had finished being sold. So it moved to the only moment it can do
/// any work: before they commit to anything.
///
/// The only pre-app screen that is **not** on the [OnboardingPage] card, and
/// deliberately so: the screens after this one ask the user for something, and a
/// card is what makes a question feel answerable. This one makes a case. It
/// keeps the shared backdrop so the card screens are plainly the same product,
/// and gives the whole window to the picture, because the picture is the
/// argument.
///
/// Nothing here about *why* the user is seeing it. Arriving from an expired
/// session and opening the app cold look the same from this screen, and both end
/// in the same tap — an explanation of the bounce is a line about the past in
/// front of the one thing to do next.
class SignInView extends StatefulWidget {
  const SignInView({
    super.key,
    required this.onSignIn,
    this.error,
    this.corner,
  });

  final VoidCallback onSignIn;

  /// A failed attempt, in the user's terms. Sits under the button rather than
  /// above the headline: the retry is the button, so the reason belongs beside
  /// it.
  final String? error;

  /// Light / Dark / System, reachable before signing in.
  final Widget? corner;

  @override
  State<SignInView> createState() => _SignInViewState();
}

class _SignInViewState extends State<SignInView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _timeline = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (kWelcomeLoopSeconds * 1000).round()),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour Reduce Motion by showing the finished grid instead of the story:
    // the whole point survives as a still, and nothing here is only legible in
    // motion. Held rather than played, exactly like OnboardingBackdrop.
    if (MediaQuery.of(context).disableAnimations) {
      _timeline.stop();
      _timeline.value = (kGridFinaleAt + 0.6) / kWelcomeLoopSeconds;
      return;
    }
    // Loops, because there is no telling how long someone looks at it: a grid
    // frozen mid-assembly is a screen that broke, and one frozen complete has
    // thrown away the only thing it had to say. The turn dissolves at its seam
    // (see [loopFade]) so the restart reads as a breath, not a cut.
    if (!_timeline.isAnimating) _timeline.repeat();
  }

  @override
  void dispose() {
    _timeline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      body: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(child: OnboardingBackdrop()),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // Just over half the window, floored so the cluster still has room
              // on a short one and capped so it doesn't sprawl on a large
              // display. Scrolls when even the floor doesn't fit — these windows
              // get resized small, and a screen you can't reach the button on is
              // one you can't leave.
              final band = (constraints.maxHeight * 0.54).clamp(240.0, 620.0);
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: band,
                        width: double.infinity,
                        child: GridGrowthBand(animation: _timeline),
                      ),
                      _SignInCopy(
                        animation: _timeline,
                        onSignIn: widget.onSignIn,
                        error: widget.error,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (widget.corner != null)
            Positioned(top: 18, right: 18, child: widget.corner!),
        ],
      ),
    );
  }
}

/// Everything under the picture: the claim, the numbers backing it, the way in.
///
/// Centred, unlike the card screens' left-aligned text. There are no rows here
/// for a paragraph to come unstuck from — only a symmetrical picture above it —
/// and centring is what keeps the column reading as that picture's caption.
class _SignInCopy extends StatefulWidget {
  const _SignInCopy({
    required this.animation,
    required this.onSignIn,
    required this.error,
  });

  /// The same turn the picture above is drawn from — the rail's numbers are that
  /// picture's arithmetic, so they read the clock, not a copy of it.
  final Animation<double> animation;
  final VoidCallback onSignIn;
  final String? error;

  @override
  State<_SignInCopy> createState() => _SignInCopyState();
}

class _SignInCopyState extends State<_SignInCopy> {
  final _railKey = GlobalKey();

  /// The rail's laid-out width, once there has been a layout to read it from.
  /// Null on the very first frame, where the button falls back to hugging its
  /// label for one frame before settling.
  double? _railWidth;

  /// Read the rail after layout and match the button to it.
  ///
  /// Measured rather than hardcoded because the rail's width is a *text*
  /// measurement: three fixed labels in the user's own UI font at the user's own
  /// scale (§11). A number typed in here would be right on one machine. It
  /// settles in one extra frame and then holds — the three labels never change,
  /// and the numbers under them are tabular, so a digit growing from 9 to 405
  /// doesn't move it.
  void _measure() {
    final width = _railKey.currentContext?.size?.width;
    if (width == null || width == _railWidth) return;
    setState(() => _railWidth = width);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    // Outside the build itself (§2) — a size can only be read once this frame
    // has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 4, 32, 44),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Every machine makes it stronger.',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineLarge,
            ),
            const SizedBox(height: 12),
            Text(
              'Grid pools the computers you already own. More of them means '
              'bigger models, more people answered at once, and none of it '
              'leaving your network.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 30),
            CapacityRail(key: _railKey, animation: widget.animation),
            const SizedBox(height: 32),
            SizedBox(
              width: _railWidth,
              child: SoftActionButton(
                // The mark leads, the payoff reads. Google's own brand rules
                // want their G on white, grey, black or Google Blue rather than
                // a palette of ours, so this is a deliberate deviation — taken
                // to keep the whole call to action in one place instead of
                // splitting it across a button and a footnote nobody reads.
                leading: const GoogleLogo(size: 18),
                // Verb plus the thing they get, not the plumbing. "Sign in with
                // Google" named the *vendor* in the one place on this screen
                // that should name the payoff — it described how the door works
                // to someone who had just been shown what is behind it. The
                // picture above spends nine seconds assembling a grid; the
                // button is where that lands.
                label: 'Sign in to build your grid',
                onPressed: widget.onSignIn,
                stretch: _railWidth != null,
                // The one thing to do on a screen that is otherwise all
                // argument, so it carries the accent rather than a white pill
                // on a white page.
                filled: true,
              ),
            ),
            if (widget.error != null) ...[
              const SizedBox(height: 14),
              Text(
                widget.error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
