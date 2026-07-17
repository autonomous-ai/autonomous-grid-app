import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// How loud a toast is, and what it means.
///
/// The app used to collapse every outcome into one grey snackbar — the shape
/// `SnackBar(content: Text(error ?? 'Deleted "$name".'))` appeared at five call
/// sites, which made a failure and a success pixel-identical. Severity is the
/// point of this enum: a toast must say *what kind* of thing happened before it
/// says anything else.
enum ToastSeverity {
  /// Neutral, informational — "Checking for updates…".
  info,

  /// It worked. The most common toast in the app.
  success,

  /// It worked, but you should know something — or it's a soft failure the user
  /// can proceed past.
  warning,

  /// It failed.
  error;

  IconData get icon => switch (this) {
    ToastSeverity.info => Icons.info_outline_rounded,
    ToastSeverity.success => Icons.check_circle_outline_rounded,
    ToastSeverity.warning => Icons.warning_amber_rounded,
    ToastSeverity.error => Icons.error_outline_rounded,
  };

  Color get color => switch (this) {
    ToastSeverity.info => AppPalette.accent,
    ToastSeverity.success => AppPalette.online,
    ToastSeverity.warning => AppPalette.warn,
    // Read from the token set rather than Theme.of(context) so severity
    // resolves without a context — the call sites are often in async code.
    ToastSeverity.error => AppTheme.pick(
      const Color(0xFFB3261E),
      const Color(0xFFF2544B),
    ),
  };

  /// An error stays up longer: it's the one you can't just re-trigger by
  /// repeating what you did.
  Duration get duration => switch (this) {
    ToastSeverity.error => const Duration(seconds: 6),
    ToastSeverity.warning => const Duration(seconds: 5),
    _ => const Duration(seconds: 4),
  };
}

/// An action button on a toast — "Download", "Undo", "Retry".
class ToastAction {
  const ToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// One notification.
class ToastSpec {
  const ToastSpec({
    required this.message,
    this.severity = ToastSeverity.info,
    this.action,
    this.duration,
    this.icon,
  });

  final String message;
  final ToastSeverity severity;
  final ToastAction? action;

  /// Overrides [ToastSeverity.duration].
  final Duration? duration;

  /// Overrides [ToastSeverity.icon] — for a toast whose glyph carries meaning
  /// the severity doesn't (a sync arrow, an open-in-new box).
  final IconData? icon;

  Duration get effectiveDuration => duration ?? severity.duration;
}

/// The app's toast host. Mount once, high in the tree; call [Toast.show] from
/// anywhere below it.
///
/// **Why not `ScaffoldMessenger`?** The app already had a hand-built overlay
/// toast for updates that looked right — glass surface, severity chip, action,
/// dismiss — while 35 `showSnackBar` sites got Material's undifferentiated grey
/// strip at the *opposite edge of the screen*. Two notification systems, one
/// pretty and sealed, one plain and everywhere, able to overlap each other. This
/// is that pretty one, unsealed: top-centre like a macOS notification banner,
/// and reachable by every call site.
class ToastScope extends StatefulWidget {
  const ToastScope({super.key, required this.child});

  final Widget child;

  @override
  State<ToastScope> createState() => ToastScopeState();

  /// The mounted host. There is exactly one [ToastScope] in the app (see
  /// `grid_app.dart`), so the toast API doesn't need a live context to find it.
  ///
  /// This is what makes `show` survive the most common call shape in the app:
  ///
  /// ```dart
  /// Navigator.of(context).pop();   // the dialog — and its context — is gone
  /// ToastScope.show(context, ...); // ...but this still works
  /// ```
  ///
  /// A context-walking lookup returns null there (Flutter forbids
  /// `findAncestorStateOfType` on a deactivated element), so the toast silently
  /// never appeared. Confirming a dialog and *then* reporting the outcome is
  /// too natural a thing to write for the API to punish it.
  static ToastScopeState? _host;

  /// Shows [spec].
  ///
  /// Safe across an `await` and safe after a `Navigator.pop` — [context] is only
  /// used as a fallback if no scope is mounted yet.
  static void show(BuildContext context, ToastSpec spec) =>
      (_host ?? of(context))?.show(spec);

  /// Convenience for the app's single most common toast shape: a message that is
  /// an error if [error] is non-null, and a success otherwise.
  ///
  /// This exists because `Text(error ?? 'Deleted "$name".')` was written five
  /// times, each collapsing the two outcomes into one indistinguishable strip.
  static void showResult(
    BuildContext context, {
    required String? error,
    required String success,
  }) => show(
    context,
    error != null
        ? ToastSpec(message: error, severity: ToastSeverity.error)
        : ToastSpec(message: success, severity: ToastSeverity.success),
  );

  /// The host. Prefer the static [show]; this remains for the explicit
  /// capture-before-await idiom.
  static ToastScopeState? of(BuildContext context) =>
      _host ?? context.findAncestorStateOfType<ToastScopeState>();
}

class ToastScopeState extends State<ToastScope> {
  /// The toast on screen, if any.
  _Entry? _current;

  /// Queued toasts. A burst (a batch delete, a sync fanning out) must not drop
  /// its own tail — the old update toast called `_entry.remove()` on every new
  /// status, so a fast sequence showed only the last one.
  final Queue<ToastSpec> _pending = Queue();

  OverlayEntry? _overlay;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    ToastScope._host = this;
  }

  @override
  void dispose() {
    // Only clear the pointer if it still refers to us: in a hot reload or a
    // test the replacement scope's initState runs before this dispose, and
    // blindly nulling would strand the live host.
    if (identical(ToastScope._host, this)) ToastScope._host = null;
    _timer?.cancel();
    _overlay?.remove();
    _overlay = null;
    super.dispose();
  }

  void show(ToastSpec spec) {
    if (_current != null) {
      // Cap the backlog: a runaway loop of failures should not queue up a
      // minute of toasts the user has to sit through.
      if (_pending.length >= 3) _pending.removeFirst();
      _pending.add(spec);
      return;
    }
    _present(spec);
  }

  void _present(ToastSpec spec) {
    final overlay = Overlay.of(context);
    final entry = _Entry(spec);
    _current = entry;

    _overlay = OverlayEntry(
      builder: (_) => _ToastHost(
        key: entry.key,
        spec: spec,
        onDismissed: _advance,
        onRequestClose: _dismiss,
      ),
    );
    overlay.insert(_overlay!);
    _timer = Timer(spec.effectiveDuration, _dismiss);
  }

  /// Plays the exit animation, then [_advance] tears the entry down.
  void _dismiss() {
    _timer?.cancel();
    _timer = null;
    final state = _current?.key.currentState;
    if (state == null) {
      _advance();
      return;
    }
    state.dismiss();
  }

  /// Removes the finished toast and shows the next queued one.
  void _advance() {
    _overlay?.remove();
    _overlay = null;
    _current = null;
    if (_pending.isNotEmpty && mounted) _present(_pending.removeFirst());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Entry {
  _Entry(this.spec);

  final ToastSpec spec;
  final GlobalKey<_ToastHostState> key = GlobalKey<_ToastHostState>();
}

/// Owns the in/out animation. The old update toast slid in over 160ms and then
/// vanished — `remove()` with no exit — which read as a glitch rather than a
/// dismissal.
class _ToastHost extends StatefulWidget {
  const _ToastHost({
    super.key,
    required this.spec,
    required this.onDismissed,
    required this.onRequestClose,
  });

  final ToastSpec spec;

  /// The exit animation finished; the host may tear the overlay down.
  final VoidCallback onDismissed;

  /// The user asked to close (tapped dismiss, or swiped).
  final VoidCallback onRequestClose;

  @override
  State<_ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<_ToastHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, -0.35),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Runs the exit, then hands back to the scope.
  Future<void> dismiss() async {
    if (!mounted) return;
    if (MediaQuery.of(context).disableAnimations) {
      widget.onDismissed();
      return;
    }
    try {
      await _controller.reverse();
    } on TickerCanceled {
      // Disposed mid-exit; the scope tears down regardless.
    }
    if (mounted) widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Positioned(
      top: 18,
      left: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.symmetric(horizontal: 18),
        child: Center(
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _fade,
              child: _ToastCard(
                spec: widget.spec,
                onClose: widget.onRequestClose,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.spec, required this.onClose});

  final ToastSpec spec;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final severity = spec.severity;
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        // Flick it up to dismiss — the gesture macOS banners answer to.
        child: Dismissible(
          key: const ValueKey('toast'),
          direction: DismissDirection.up,
          onDismissed: (_) => onClose(),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppGlass.surfaceFill,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: AppPalette.divider),
              boxShadow: AppGlass.shadow,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SeverityIcon(
                    icon: spec.icon ?? severity.icon,
                    color: severity.color,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      spec.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (spec.action case final action?) ...[
                    const SizedBox(width: 10),
                    TextButton(
                      // Compact: the toast is a thin strip, not a page.
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppControl.heightSmall),
                        padding: AppControl.paddingSmall,
                      ),
                      onPressed: () {
                        action.onPressed();
                        onClose();
                      },
                      child: Text(action.label),
                    ),
                  ],
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: onClose,
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    color: AppPalette.textFaint,
                    icon: const Icon(Icons.close_rounded),
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

class _SeverityIcon extends StatelessWidget {
  const _SeverityIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}
