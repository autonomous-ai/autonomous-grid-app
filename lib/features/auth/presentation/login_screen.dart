import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/layouts/widgets/theme_mode_picker.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/auth_controller.dart';
import '../logic/auth_state.dart';
import '../logic/session_expiry_controller.dart';
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
    // We land here from an expired session (RootView routes needsLogin -> login),
    // so tell the user why they're back at sign-in instead of the app.
    final sessionExpired =
        ref.watch(sessionExpiryProvider) == SessionExpiry.needsLogin;

    return Scaffold(
      body: Stack(
        children: [
          // Layered ambient background — deepest and slowest at the back, the
          // faint grid texture over it, both well below the content. Motion is
          // deliberately barely-there: the screen should feel alive, not busy.
          const Positioned.fill(child: IgnorePointer(child: _LoginBackdrop())),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: switch (state) {
                  AuthAwaitingApproval(:final url) => _ApprovalView(
                    url: url,
                    onCancel: controller.cancel,
                  ),
                  AuthStarting() ||
                  AuthSuccess() => const _Busy(label: 'Signing in…'),
                  AuthFailure(:final message) => _SignIn(
                    onSignIn: controller.login,
                    error: message,
                    sessionExpired: sessionExpired,
                  ),
                  AuthIdle() => _SignIn(
                    onSignIn: controller.login,
                    sessionExpired: sessionExpired,
                  ),
                },
              ),
            ),
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
/// account menu's [ThemeModePicker] uses — so the choice is available before the
/// user signs in, and survives a restart. Rendered as three quiet icon buttons
/// in a pill rather than the menu's labelled block, to sit lightly in the corner.
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
  const _SignIn({
    required this.onSignIn,
    this.error,
    this.sessionExpired = false,
  });

  final VoidCallback onSignIn;
  final String? error;

  /// True when the user was routed here because their session expired, so the
  /// subtitle explains the bounce instead of showing the product tagline.
  final bool sessionExpired;

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn>
    with SingleTickerProviderStateMixin {
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
  late final Animation<Offset> _slide =
      Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
        CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic),
      );

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
            if (widget.sessionExpired) ...[
              const _SessionExpiredBadge(),
              const SizedBox(height: 10),
            ],
            Text(
              // With the badge already naming the expiry, the subtitle is just
              // the next action — so it doesn't say "expired" twice.
              widget.sessionExpired
                  ? 'Sign in again to continue.'
                  : 'One private endpoint for the AI models you run.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            _GoogleSignInButton(onPressed: widget.onSignIn),
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

/// The Google OAuth button — a real "Sign in with Google" control: white
/// surface, hairline rim, the four-colour "G", and a soft lift. Deliberately
/// not a `FilledButton` in the app accent: an OAuth button is expected to look
/// like Google's, and a white pill with the G reads as the trusted, official
/// path far more than an indigo one.
class _GoogleSignInButton extends StatefulWidget {
  const _GoogleSignInButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Google's guidance is a white button with dark text on light surfaces; on
    // our dark charcoal we lift to a slightly raised surface so it stays a
    // distinct, tappable pill instead of sinking into the background.
    final base = AppTheme.pick(Colors.white, const Color(0xFF2A2A2A));
    // On hover the surface shifts one quiet step — a hair grey on white, a hair
    // brighter on charcoal — the small "yes, this is clickable" a desktop user
    // expects from a pointer.
    final hoverSurface = AppTheme.pick(
      const Color(0xFFF7F7F6),
      const Color(0xFF333333),
    );
    final surface = _hovered ? hoverSurface : base;
    final textColor = AppTheme.pick(
      const Color(0xFF1F1F1F),
      const Color(0xFFF5F5F5),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // A touch more lift on hover, so the pill rises to meet the cursor.
          boxShadow: _hovered ? AppGlass.shadow : AppGlass.cardShadow,
        ),
        child: Material(
          color: surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onPressed,
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppGlass.hair),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GoogleLogo(size: 18),
                  const SizedBox(width: 12),
                  Text(
                    'Sign in with Google',
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
    );
  }
}

/// A small warn-toned chip that names *why* the user is back at sign-in when a
/// session expired — so the bounce reads as an event, not a plain tagline. Uses
/// the shared [AppPalette.warn] token over a faint wash of the same hue.
class _SessionExpiredBadge extends StatelessWidget {
  const _SessionExpiredBadge();

  @override
  Widget build(BuildContext context) {
    final warn = AppPalette.warn;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: warn.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded, size: 13, color: warn),
            const SizedBox(width: 6),
            Text(
              'Session expired',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: warn,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
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

class _ApprovalView extends StatelessWidget {
  const _ApprovalView({required this.url, required this.onCancel});

  final String url;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Finish signing in', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'We opened Grid sign-in in your browser. Approve the sign-in there '
          'to continue.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Waiting for approval…'),
          ],
        ),
        const SizedBox(height: 24),
        // Fallbacks, de-emphasized — the browser usually opened already.
        _BrowserFallback(url: url),
        const SizedBox(height: 6),
        Center(
          child: TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ),
      ],
    );
  }
}

/// Collapsed "browser didn't open?" helper — the open button + copyable URL.
class _BrowserFallback extends StatelessWidget {
  const _BrowserFallback({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      // The fallback is two controls in a row; packed tight they read as one
      // knot of UI. Give them room to be two separate things.
      childrenPadding: const EdgeInsets.only(top: 6, bottom: 14),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      title: const Text("Browser didn't open?"),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          // Quiet on purpose: the browser has usually opened already, and this
          // is the way out when it didn't. A filled button here shouts louder
          // than the sign-in the user is meant to go and approve.
          child: OutlinedButton.icon(
            onPressed: () => _openInBrowser(url),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Open in browser'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppPalette.accent,
              backgroundColor: Colors.white,
              side: BorderSide(color: AppPalette.divider),
              // Without this, Material pads the button out to a 48px tap target
              // and it floats in a box half again its own height.
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
              textStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        _CopyField(label: 'Or paste this link', value: url),
      ],
    );
  }
}

/// The sign-in link, and a button that copies it.
///
/// A quiet filled row rather than an outlined input: it isn't something to type
/// into, and the boxed field was the only outlined control on the screen. The
/// copy says so instead of leaving the user to guess whether it worked.
class _CopyField extends StatelessWidget {
  const _CopyField({required this.label, required this.value});

  final String label;
  final String value;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied.')));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AppPalette.textFaint,
          ),
        ),
        const SizedBox(height: 7),
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppPalette.cardBg,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Copy link',
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  color: AppPalette.textSecondary,
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => _copy(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label),
      ],
    );
  }
}
