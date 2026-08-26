import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/onboarding_backdrop.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/grid_growth.dart';
import '../logic/welcome_controller.dart';
import 'widgets/capacity_rail.dart';
import 'widgets/grid_growth_band.dart';

/// The one screen between finishing setup and using the app: what a grid is
/// *for*, shown rather than claimed.
///
/// Seen exactly once in a user's life (see [welcomeSeenProvider]), which decides
/// everything about it — one idea, no choices, and a way in that is always the
/// brightest thing on screen.
///
/// The only pre-app screen that is **not** on the [OnboardingPage] card, and
/// deliberately so: the other three ask the user for something, and a card is
/// what makes a question feel answerable. This one asks for nothing. It keeps
/// the shared backdrop so it is plainly the same product, and gives the whole
/// window to the picture, because the picture is the entire argument.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _timeline = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (kWelcomeLoopSeconds * 1000).round()),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour Reduce Motion by holding one frame instead of playing the story:
    // late enough that all three numbers have said what they have to say, early
    // enough that the picture is still whole rather than half-dissolved. The
    // whole point survives as a still — nothing here is only legible in motion.
    // Held rather than played, exactly like OnboardingBackdrop.
    if (MediaQuery.of(context).disableAnimations) {
      _timeline.stop();
      _timeline.value = kSettledAt / kWelcomeLoopSeconds;
      return;
    }
    // Loops, because there is no telling how long someone looks at it: a grid
    // frozen mid-assembly is a screen that broke, and one frozen complete has
    // thrown away the only thing it had to say. The turn dissolves at its seam
    // (see [loopFade]) so the restart reads as a breath, not a cut — and the
    // last wave is still arriving as it goes, which is the only honest way to
    // draw "and it keeps going".
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
                      _WelcomeCopy(animation: _timeline),
                    ],
                  ),
                ),
              );
            },
          ),
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
class _WelcomeCopy extends ConsumerWidget {
  const _WelcomeCopy({required this.animation});

  /// The same turn the picture above is drawn from — the rail's numbers are that
  /// picture's arithmetic, so they read the clock, not a copy of it.
  final Animation<double> animation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
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
              'bigger models, more people answered at once — and none of it '
              'leaving your network.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 30),
            CapacityRail(animation: animation),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () =>
                      ref.read(welcomeSeenProvider.notifier).markSeen(),
                  child: const Text('Enter Grid'),
                ),
                const SizedBox(width: 14),
                // Says the screen is not a step being added to their life. Not
                // `textFaint`, which lands near 3.3:1 on this ground (§11).
                Text(
                  "You'll only see this once.",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
