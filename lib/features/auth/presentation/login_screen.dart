import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/theme_mode_labels.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../../network/presentation/detail_widgets.dart';
import '../logic/auth_controller.dart';
import '../logic/auth_state.dart';
import 'google_logo.dart';

/// Opens [url] in the user's default browser. Returns false if it could not be
/// launched (malformed URL or no handler) so callers can fall back to copy.
Future<bool> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Device-flow login. Triggers `grid login --no-browser`, shows the URL +
/// code while the CLI polls, and flips to the app on success.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Auto-open the browser the moment the device-flow URL streams in, so the
    // user doesn't have to copy/paste it. Fires once per transition; the copy
    // fields and the "Open in browser" button below stay as fallbacks.
    ref.listen<AuthState>(authControllerProvider, (prev, next) {
      if (next is AuthAwaitingApproval && prev is! AuthAwaitingApproval) {
        _openInBrowser(next.url);
      }
    });

    final state = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);

    return Scaffold(
      body: Stack(
        children: [
          // Layered ambient background — deepest and slowest at the back, the
          // faint grid texture over it, both well below the content. Motion is
          // deliberately barely-there: the screen should feel alive, not busy.
          const Positioned.fill(child: IgnorePointer(child: _LoginBackdrop())),
          // Center the card when the window is tall enough, but let it scroll
          // rather than overflow when the window is short (resized small, or a
          // laptop with the dock/menu-bar eating height). LayoutBuilder +
          // minHeight-constrained IntrinsicHeight is the standard "center if it
          // fits, scroll if it doesn't" pattern.
          LayoutBuilder(
            builder: (context, constraints) {
              final content = ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: switch (state) {
                    AuthAwaitingApproval(:final url, :final userCode) =>
                      _ApprovalView(
                        url: url,
                        userCode: userCode,
                        onCancel: controller.cancel,
                      ),
                    AuthStarting() ||
                    AuthSuccess() => const _Busy(label: 'Signing in…'),
                    AuthFailure(:final message) => _SignIn(
                      onSignIn: controller.login,
                      error: message,
                    ),
                    AuthIdle() => _SignIn(onSignIn: controller.login),
                  },
                ),
              );
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(child: content),
                ),
              );
            },
          ),
          // Light / Dark / System, tucked in the top-right so the choice is
          // reachable before signing in — it writes the same persisted
          // themeModeProvider the account menu does, so the pick sticks. Kept
          // clear of the macOS title-bar / traffic-light strip up top.
          const Positioned(top: 18, right: 18, child: _ThemeToggle()),
        ],
      ),
    );
  }
}

/// The ambient background: a slow aurora wash plus a faint, static dot grid.
/// One long looping controller drives the aurora; the grid is painted once and
/// only re-rasterised as the aurora animates over it. Kept extremely low
/// contrast so it reads as *atmosphere*, never as decoration competing with the
/// sign-in card. Ticker-driven, so it idles when the window isn't visible.
class _LoginBackdrop extends StatefulWidget {
  const _LoginBackdrop();

  @override
  State<_LoginBackdrop> createState() => _LoginBackdropState();
}

class _LoginBackdropState extends State<_LoginBackdrop>
    with SingleTickerProviderStateMixin {
  // 24s is slow enough that the drift is felt more than seen — the point is a
  // living surface, not a moving one.
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat();

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _drift,
        builder: (context, _) => CustomPaint(
          painter: _BackdropPainter(
            t: _drift.value,
            accent: AppPalette.accent,
            bolt: AppPalette.brandBolt,
            isDark: AppTheme.isDark,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.t,
    required this.accent,
    required this.bolt,
    required this.isDark,
  });

  /// Loop phase in [0, 1).
  final double t;
  final Color accent;
  final Color bolt;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    _paintAurora(canvas, size);
    _paintGrid(canvas, size);
  }

  /// Two soft accent blobs drifting on gentle Lissajous paths — one indigo, one
  /// a whisper of the brand gold — well under the content. Alpha is tiny; on a
  /// white surface even this reads clearly, so dark gets a touch more.
  void _paintAurora(Canvas canvas, Size size) {
    final twoPi = 2 * math.pi;
    // Two independent phases from the single loop so the blobs never move in
    // lockstep.
    final a = t * twoPi;
    final b = (t * twoPi) + 2.1;

    // Anchored on a diagonal — indigo top-right, gold bottom-left — so the
    // wash spans the frame rather than pooling in one corner. Each drifts around
    // its anchor on its own phase.
    final blobA = Offset(
      size.width * (0.70 + 0.08 * math.cos(a)),
      size.height * (0.28 + 0.07 * math.sin(a * 0.8)),
    );
    final blobB = Offset(
      size.width * (0.28 + 0.08 * math.cos(b * 0.7)),
      size.height * (0.72 + 0.08 * math.sin(b)),
    );

    final radius = size.shortestSide * 0.55;
    final aAlpha = isDark ? 0.10 : 0.06;
    final bAlpha = isDark ? 0.07 : 0.045;

    _blob(canvas, blobA, radius, accent.withValues(alpha: aAlpha));
    _blob(canvas, blobB, radius * 0.9, bolt.withValues(alpha: bAlpha));
  }

  void _blob(Canvas canvas, Offset center, double radius, Color color) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  /// A faint dot grid — a nod to the product name. Fades out toward the edges via
  /// a radial mask so it never hits a hard border; densest, still-quiet, center.
  void _paintGrid(Canvas canvas, Size size) {
    const spacing = 34.0;
    final dot = (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.035 : 0.028,
    );
    final paint = Paint()..color = dot;

    final center = Offset(size.width / 2, size.height / 2);
    final maxDist = size.shortestSide * 0.62;

    for (double x = spacing / 2; x < size.width; x += spacing) {
      for (double y = spacing / 2; y < size.height; y += spacing) {
        final d = (Offset(x, y) - center).distance;
        if (d > maxDist) continue;
        // Fade the dot as it approaches the mask edge.
        final falloff = 1 - (d / maxDist);
        canvas.drawCircle(
          Offset(x, y),
          1.1,
          paint..color = dot.withValues(alpha: dot.a * falloff),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter old) =>
      old.t != t || old.isDark != isDark;
}

/// A compact Light / Dark / System switch for the login screen's corner. Reads
/// and writes the same persisted [themeModeProvider] / [chatPrefsProvider] the
/// Appearance settings screen does — so the choice is available before the user
/// signs in, and survives a restart. Rendered as three quiet icon buttons in a
/// pill, to sit lightly in the corner.
class _ThemeToggle extends ConsumerWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeModeProvider);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppGlass.hair),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ThemeMode.values)
              _ThemeToggleButton(
                icon: _loginThemeIcon(mode),
                tooltip: themeModeLabel(mode),
                selected: mode == current,
                onTap: () =>
                    ref.read(chatPrefsProvider.notifier).setThemeMode(mode),
              ),
          ],
        ),
      ),
    );
  }
}

/// The glyph for a theme choice *on the login screen*. Diverges from the shared
/// [themeModeIcon] only for [ThemeMode.system]: a split light/dark disc reads as
/// "follow the OS" far more clearly than the shared auto-badge, which renders
/// close to a settings cog at this small size. Light/Dark keep the sun/moon.
IconData _loginThemeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.system => Icons.brightness_6_outlined,
  _ => themeModeIcon(mode),
};

/// One icon cell of [_ThemeToggle] — accent-filled when it's the active mode,
/// otherwise a quiet tappable glyph.
class _ThemeToggleButton extends StatelessWidget {
  const _ThemeToggleButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? AppPalette.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 16, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// The sign-in view. Wrapped in a one-shot fade + slide-up so the screen
/// *arrives* rather than blinking in — the small motion is most of what reads
/// as "polished" in the first moment on screen.
class _SignIn extends StatefulWidget {
  const _SignIn({required this.onSignIn, this.error});

  final VoidCallback onSignIn;
  final String? error;

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _intro,
    curve: Curves.easeOut,
  );

  // A gentle rise — 12px up into place. easeOutCubic settles softly instead of
  // stopping dead.
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LogoWithGlow(),
            const SizedBox(height: 18),
            Text('Grid', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            // Nothing about *why* the user is here. Arriving from an expired
            // session and opening the app cold look the same from this screen,
            // and both end in the same tap — an explanation of the bounce is a
            // line about the past in front of the one thing to do next.
            Text(
              'One private endpoint for the AI models you run.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            SoftActionButton(
              leading: const GoogleLogo(size: 18),
              label: 'Sign in with Google',
              onPressed: widget.onSignIn,
            ),
            if (widget.error != null) ...[
              const SizedBox(height: 16),
              Text(
                widget.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 28),
            // Anchors the bottom of the stack so the screen doesn't feel
            // top-heavy, and quietly reassures on a sign-in screen.
            _SecureNote(),
          ],
        ),
      ),
    );
  }
}

/// The brand mark sitting in a soft radial halo. The glow is a faint accent
/// wash — present enough to give the logo a "hero" moment, quiet enough not to
/// fight the app's calm Codex surfaces. Tuned per brightness so it reads on
/// both white and charcoal.
class _LogoWithGlow extends StatefulWidget {
  @override
  State<_LogoWithGlow> createState() => _LogoWithGlowState();
}

class _LogoWithGlowState extends State<_LogoWithGlow>
    with SingleTickerProviderStateMixin {
  // The halo "breathes" — a slow 4s in-and-out that gives the mark a heartbeat
  // without ever drawing the eye. Only the glow animates; the tile stays still,
  // so the logo reads as solid while the light around it lives.
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat(reverse: true);

  late final Animation<double> _pulse = CurvedAnimation(
    parent: _breathe,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseAlpha = AppTheme.pick(0.16, 0.28);
    return SizedBox(
      width: 168,
      height: 168,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ambient halo behind the mark — scale and opacity ease together, so
          // it swells slightly brighter as it grows.
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final glow = AppPalette.accent.withValues(
                // Brightest at full inhale; a shade dimmer at rest.
                alpha: baseAlpha * (0.82 + 0.18 * _pulse.value),
              );
              return Transform.scale(
                scale: 0.94 + 0.06 * _pulse.value,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [glow, glow.withValues(alpha: 0)],
                      stops: const [0.0, 1.0],
                    ),
                  ),
                  child: const SizedBox(width: 168, height: 168),
                ),
              );
            },
          ),
          // The logo itself, clipped to a rounded square with a hairline rim and
          // a soft lift so it reads as a crafted tile, not a raw pasted image.
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppGlass.hair),
              boxShadow: AppCard.shadow,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset(
                'assets/brand/grid_logo_bg.png',
                width: 76,
                height: 76,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quiet "your sign-in is secure" footer note. Low-contrast on purpose — it
/// reassures without competing with the button above it.
class _SecureNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_outline_rounded, size: 13, color: AppPalette.textFaint),
        const SizedBox(width: 6),
        Text(
          'Secure sign-in',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppPalette.textFaint,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );
  }
}

/// The "Finish signing in" view — shown while the browser is open and the CLI
/// polls for approval. Wrapped in the same fade + slide-up as [_SignIn] so the
/// transition from the sign-in card reads as one continuous screen, not a jump.
///
/// The waiting moment is framed as a *handshake*: an orbiting brand seal, a
/// three-step timeline (browser opened → approve → connect) that tells the user
/// exactly where they are, and a beaconing status pill — so an inherently
/// idle screen still feels like progress toward something safe. All of the
/// sign-in logic is untouched: [url] auto-opens upstream, [_BrowserFallback]
/// carries the open/copy fallbacks, and [onCancel] backs out of the flow.
class _ApprovalView extends StatefulWidget {
  const _ApprovalView({
    required this.url,
    required this.userCode,
    required this.onCancel,
  });

  final String url;

  /// The device-flow code the user should see match in their browser — shown on
  /// the card as a "verify this code" trust cue.
  final String userCode;
  final VoidCallback onCancel;

  @override
  State<_ApprovalView> createState() => _ApprovalViewState();
}

class _ApprovalViewState extends State<_ApprovalView>
    with SingleTickerProviderStateMixin {
  // Mirror _SignIn's arrival so switching from sign-in to approval glides.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _intro,
    curve: Curves.easeOut,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The card holds only the "what's happening" story — seal, heading,
            // timeline, status. The fallback + cancel sit *below* it, so the way
            // out never competes with the primary "go approve" moment.
            _ApprovalCard(theme: theme, userCode: widget.userCode),
            const SizedBox(height: 18),
            // Fallbacks, de-emphasized — the browser usually opened already.
            _BrowserFallback(url: widget.url),
            const SizedBox(height: 6),
            Center(
              child: TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frosted focal card for the approval view: the orbiting seal, the heading
/// and body copy, the handshake timeline, and the status pill — everything that
/// tells the user "we're waiting on you, and it's safe." Uses the app's own
/// [AppCard] recipe so it reads as kin to the rest of the product's surfaces.
class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.theme, required this.userCode});

  final ThemeData theme;
  final String userCode;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppCard.hair),
        boxShadow: AppCard.heroShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _HandshakeSeal(),
          const SizedBox(height: 18),
          // Eyebrow — names the moment ("this is Grid, and it's the secure
          // sign-in") above the heading, in the accent with wide tracking.
          Text(
            'GRID · SECURE SIGN-IN',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: AppPalette.accent,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Finish signing in',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'We opened Grid in your browser. Approve the request there '
            "and you'll land right back here.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          const _HandshakeSteps(),
          const SizedBox(height: 20),
          const _WaitingStatus(),
          if (userCode.isNotEmpty) ...[
            const SizedBox(height: 16),
            _VerifyCode(userCode: userCode),
          ],
        ],
      ),
    );
  }
}

/// The animated brand seal: the Grid glyph on an accent tile, ringed by a single
/// arc that orbits it. Reuses the "breathing tile in a soft halo" language of
/// [_LogoWithGlow] so the two screens feel authored by the same hand — but here
/// the orbit doubles as the loading indicator, replacing the bare spinner.
class _HandshakeSeal extends StatefulWidget {
  const _HandshakeSeal();

  @override
  State<_HandshakeSeal> createState() => _HandshakeSealState();
}

class _HandshakeSealState extends State<_HandshakeSeal>
    with SingleTickerProviderStateMixin {
  // 2.6s per revolution — brisk enough to read as "working," slow enough to stay
  // calm. One controller drives both the orbit angle and the halo breath.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: 104,
        height: 104,
        child: AnimatedBuilder(
          animation: _spin,
          builder: (context, child) {
            // Halo breathes over the loop: brightest mid-revolution, dimmest at
            // the seam — a heartbeat behind the mark.
            final breath = (math.sin(_spin.value * 2 * math.pi) + 1) / 2;
            return Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(104, 104),
                  painter: _OrbitPainter(
                    t: _spin.value,
                    breath: breath,
                    accent: AppPalette.accent,
                    isDark: AppTheme.isDark,
                  ),
                ),
                child!,
              ],
            );
          },
          // The tile is static — only the rings and halo move — so the mark reads
          // as solid while the light around it lives. It's the real app logo
          // (same asset as the sign-in screen's _LogoWithGlow), clipped to a
          // rounded square with a hairline rim so the two screens share a mark.
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppGlass.hair),
              boxShadow: [
                BoxShadow(
                  color: AppPalette.accent.withValues(alpha: 0.32),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                  spreadRadius: -6,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: Image.asset(
                'assets/brand/grid_logo_bg.png',
                width: 64,
                height: 64,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The orbit ring + halo behind the seal tile. A soft accent halo swells with
/// [breath]; a bright arc sweeps the track at angle [t], leaving a faint full
/// ring behind it so the circle always reads as closed.
class _OrbitPainter extends CustomPainter {
  const _OrbitPainter({
    required this.t,
    required this.breath,
    required this.accent,
    required this.isDark,
  });

  /// Orbit phase in [0, 1).
  final double t;

  /// Halo breath in [0, 1].
  final double breath;
  final Color accent;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // The orbit ring rides near the edge of the halo.
    final rOuter = size.width / 2 - 3;
    final twoPi = 2 * math.pi;

    // Ambient halo — a radial wash that pulses with the breath, wider swing than
    // before so the glow visibly grows and shrinks. Light needs a higher floor:
    // a low-alpha accent all but vanishes on white.
    final haloAlpha = (isDark ? 0.28 : 0.24) * (0.55 + 0.45 * breath);
    final halo = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: haloAlpha),
          accent.withValues(alpha: 0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: size.width / 2));
    canvas.drawCircle(center, size.width / 2, halo);

    // The full track behind the outer arc — firmer than before so the ring reads
    // as a solid orbit the light sweeps around, not a faint hint.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..color = accent.withValues(alpha: isDark ? 0.24 : 0.18);
    canvas.drawCircle(center, rOuter, track);

    final outerRect = Rect.fromCircle(center: center, radius: rOuter);

    // The bright ~150° comet sweep, clockwise. A sweep gradient fades from a
    // transparent tail to a solid accent head.
    final outerAngle = t * twoPi;
    final outerSweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        transform: GradientRotation(outerAngle),
        colors: [
          accent.withValues(alpha: 0),
          accent.withValues(alpha: 0),
          accent,
          accent.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.30, 0.60, 0.68],
      ).createShader(outerRect);
    canvas.drawArc(outerRect, outerAngle, 2.5, false, outerSweep);

    // Comet head — a small bright glow dot at the leading tip of the outer arc,
    // giving the sweep a clear direction and a bit of spark.
    final headAngle = outerAngle + 2.5;
    final head = Offset(
      center.dx + rOuter * math.cos(headAngle),
      center.dy + rOuter * math.sin(headAngle),
    );
    canvas.drawCircle(
      head,
      5,
      Paint()
        ..shader = RadialGradient(
          colors: [accent, accent.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: head, radius: 5)),
    );
    canvas.drawCircle(head, 2, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.t != t || old.breath != breath || old.isDark != isDark;
}

/// The three-step handshake timeline: browser opened (done) → approve (active,
/// where the user is now) → connect (upcoming). Turns a static "waiting" line
/// into a sense of place — the user can see they're one approval away from done.
class _HandshakeSteps extends StatelessWidget {
  const _HandshakeSteps();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _HandshakeStep(
          icon: Icons.check_rounded,
          label: 'Browser\nopened',
          status: _StepStatus.done,
          isFirst: true,
        ),
        // prevDone drives the whole connector into this step in one colour, so
        // the rail between two dots never splits at the midpoint. Step 1 is
        // done → the line into "Approve" is filled; step 2 is only active (not
        // done) → the line into "Connect" stays a quiet hairline.
        _HandshakeStep(
          icon: Icons.touch_app_outlined,
          label: 'Approve\naccess',
          status: _StepStatus.active,
          prevDone: true,
        ),
        _HandshakeStep(
          icon: Icons.lock_outline_rounded,
          label: 'Connect',
          status: _StepStatus.upcoming,
          prevDone: false,
          isLast: true,
        ),
      ],
    );
  }
}

enum _StepStatus { done, active, upcoming }

class _HandshakeStep extends StatelessWidget {
  const _HandshakeStep({
    required this.icon,
    required this.label,
    required this.status,
    this.isFirst = false,
    this.isLast = false,
    this.prevDone = false,
  });

  final IconData icon;
  final String label;
  final _StepStatus status;
  final bool isFirst;
  final bool isLast;

  /// Whether the step *before* this one is complete — decides the colour of the
  /// whole rail leading into this dot, so a segment between two dots is one
  /// solid colour rather than two halves painted by different steps.
  final bool prevDone;

  /// The rail on this step's right is filled once this step itself is complete —
  /// which is exactly the [prevDone] the next step reads, so the shared segment
  /// stays one colour.
  bool get _railFilled => status == _StepStatus.done;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                // A between-dots segment is two halves painted by two adjacent
                // steps, so both must key off the SAME fact to avoid splitting
                // at the midpoint. The left half here keys off [prevDone] (did
                // the step before me complete?); the right half keys off my own
                // completion (_railFilled) — which is exactly what the *next*
                // step reads as its prevDone. So each full segment is one colour.
                Expanded(
                  child: isFirst ? const SizedBox() : _rail(filled: prevDone),
                ),
                _dot(),
                Expanded(
                  child: isLast ? const SizedBox() : _rail(filled: _railFilled),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                fontWeight: status == _StepStatus.active
                    ? FontWeight.w600
                    : FontWeight.w500,
                color: switch (status) {
                  _StepStatus.active => AppPalette.textPrimary,
                  _StepStatus.done => AppPalette.textSecondary,
                  _StepStatus.upcoming => AppPalette.textFaint,
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One half of a rail segment. [filled] = the segment connects to a completed
  /// step, so it's drawn in a strong accent; otherwise a clearly-lighter track
  /// tint, so "done" vs "still to do" reads at a glance instead of both halves
  /// looking the same faint grey.
  Widget _rail({required bool filled}) {
    return Container(
      height: 2.5,
      color: filled
          ? AppPalette.accent
          : AppPalette.accent.withValues(alpha: AppTheme.pick(0.16, 0.22)),
    );
  }

  Widget _dot() {
    switch (status) {
      case _StepStatus.done:
        // A firmer accent wash + rim than the collapsed state so a completed
        // step reads clearly on white, without competing with the filled
        // active dot next to it.
        return Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppCard.tint25,
            border: Border.all(color: AppPalette.accent.withValues(alpha: 0.7)),
          ),
          child: Icon(icon, size: 20, color: AppCard.accentStrong),
        );
      case _StepStatus.active:
        return _ActiveDot(icon: icon);
      case _StepStatus.upcoming:
        return Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppCard.inset,
            border: Border.all(color: AppCard.insetHair),
          ),
          child: Icon(icon, size: 19, color: AppPalette.textFaint),
        );
    }
  }
}

/// The active step's dot: an accent-filled circle with a slow breathing halo
/// ring, so the eye lands on "you are here" without a hard blink.
class _ActiveDot extends StatefulWidget {
  const _ActiveDot({required this.icon});
  final IconData icon;

  @override
  State<_ActiveDot> createState() => _ActiveDotState();
}

class _ActiveDotState extends State<_ActiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final glow = 4.0 + 3.0 * _pulse.value;
        return Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppPalette.accent, AppCard.accentStrong],
            ),
            boxShadow: [
              BoxShadow(
                color: AppPalette.accent.withValues(alpha: 0.28),
                blurRadius: glow,
                spreadRadius: glow,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Icon(widget.icon, size: 19, color: Colors.white),
    );
  }
}

/// The "verify this code" trust cue — the same device-flow code the browser
/// shows, so the user can confirm they're approving *this* machine and not a
/// phishing prompt. Quiet and mono, sitting under the status pill.
class _VerifyCode extends StatelessWidget {
  const _VerifyCode({required this.userCode});

  final String userCode;

  @override
  Widget build(BuildContext context) {
    // FittedBox scales the line down rather than overflowing if a long code
    // pushes the row past the card's width.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_rounded, size: 13, color: AppPalette.textFaint),
          const SizedBox(width: 7),
          Text(
            'Verify code ',
            style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
          ),
          Text(
            userCode,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              fontFamily: AppFont.mono,
              fontFamilyFallback: AppFont.monoFallback,
              color: AppPalette.textPrimary,
            ),
          ),
          Text(
            '  ·  ${_thisDeviceLabel()}',
            style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }

  /// "this Mac" / "this PC" / "this device" — names the machine being authorized
  /// per the actual platform, so the trust cue reads true on each OS.
  static String _thisDeviceLabel() {
    if (Platform.isMacOS) return 'this Mac';
    if (Platform.isWindows) return 'this PC';
    return 'this device';
  }
}

/// The "waiting for approval" status pill — an accent chip with a pinging beacon,
/// so the wait reads as an active, expected state rather than a stalled one.
class _WaitingStatus extends StatelessWidget {
  const _WaitingStatus();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.tint10,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppCard.tint18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 8, 16, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Beacon(),
            const SizedBox(width: 10),
            Text(
              'Waiting for approval…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppPalette.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small accent dot with a ping ring expanding out of it — the classic "live"
/// signal, telling the user something is actively listening for their approval.
class _Beacon extends StatefulWidget {
  const _Beacon();

  @override
  State<_Beacon> createState() => _BeaconState();
}

class _BeaconState extends State<_Beacon> with SingleTickerProviderStateMixin {
  late final AnimationController _ping = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 10,
      height: 10,
      child: AnimatedBuilder(
        animation: _ping,
        builder: (context, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              // The expanding, fading ring.
              Transform.scale(
                scale: 1 + 2.2 * _ping.value,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppPalette.accent.withValues(
                      alpha: 0.5 * (1 - _ping.value),
                    ),
                  ),
                ),
              ),
              child!,
            ],
          );
        },
        // The solid core dot.
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppPalette.accent,
          ),
        ),
      ),
    );
  }
}

/// The "Browser didn't open?" fallback — a self-contained boxed disclosure.
///
/// Header and body live inside one framed box (matching the sign-in card's
/// language), so the whole control reads as a single object rather than a bare
/// tappable line. Collapsed by default — the browser has usually opened
/// already; this is the way out when it didn't. Logic is unchanged:
/// [_openInBrowser] opens the URL, and the copy control writes it to the
/// clipboard.
class _BrowserFallback extends StatefulWidget {
  const _BrowserFallback({required this.url});
  final String url;

  @override
  State<_BrowserFallback> createState() => _BrowserFallbackState();
}

class _BrowserFallbackState extends State<_BrowserFallback> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        // A firmer rim than the plain hairline: the inset fill sits so close to
        // the page on white that AppCard.hair lets the box dissolve into it.
        // AppGlass.lift keeps a visible edge so it reads as a distinct object.
        border: Border.all(color: AppGlass.lift),
      ),
      // Clip so the header's ink splash stays inside the rounded box.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The header row — title + chevron, both inside the box.
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Browser didn't open?",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                      ),
                      // Chevron rotates 180° when expanded.
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // The body — animates open/closed. AnimatedSize gives the reveal a
            // smooth height transition rather than a hard pop.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _open
                  ? _FallbackBody(url: widget.url)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// The expanded contents of [_BrowserFallback]: a one-line instruction, a
/// "copy sign-in link" action, and the raw URL in a mono chip — so a user whose
/// browser stayed shut can get the link out by hand.
class _FallbackBody extends StatelessWidget {
  const _FallbackBody({required this.url});
  final String url;

  void _copy(BuildContext context) =>
      copyToClipboard(context, url, message: 'Link copied.');

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Sits under the header, inset to align with the title above it.
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A hairline splits the header from the body without a hard edge.
          Divider(height: 1, thickness: 1, color: AppCard.insetHair),
          const SizedBox(height: 14),
          Text(
            'Open this link manually to continue:',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 12),
          // The primary way out — copy the link, in the accent so it reads as
          // the action. A tap copies and confirms via the snackbar.
          _CopyLinkButton(onTap: () => _copy(context)),
          const SizedBox(height: 12),
          // The raw URL, in a recessed mono chip so the user can see exactly
          // what they'd be opening. Selectable for a manual copy, too.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppCard.base,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppCard.insetHair),
            ),
            child: SelectableText(
              url,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                fontFamily: AppFont.mono,
                fontFamilyFallback: AppFont.monoFallback,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The accent "Copy sign-in link" affordance — a text + copy-icon row that
/// lights on hover, matching the prototype's inline link treatment.
class _CopyLinkButton extends StatefulWidget {
  const _CopyLinkButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CopyLinkButton> createState() => _CopyLinkButtonState();
}

class _CopyLinkButtonState extends State<_CopyLinkButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Copy sign-in link',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppPalette.accent,
                decoration: _hovered
                    ? TextDecoration.underline
                    : TextDecoration.none,
                decorationColor: AppPalette.accent,
              ),
            ),
            const SizedBox(width: 7),
            Icon(Icons.copy_rounded, size: 14, color: AppPalette.accent),
          ],
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return LoadingView(message: label);
  }
}
