/// The controls at the foot of a composer, shared by every box in the app that
/// sends something: the chat's, and Code's box for asking the grid to run a task.
///
/// They live here rather than beside one of them because the two boxes have to
/// look like the same control — a person moving between the two halves of the
/// app is doing the same thing in both, and a Send that is a different size or a
/// different weight on one screen reads as a different action.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Kills the Material ink ripple on a composer button.
///
/// The app's ThemeData sets `splashFactory: InkRipple.splashFactory` app-wide —
/// a circle that expands from the click point over ~600ms. That is an Android
/// gesture idiom: on macOS a click lands instantly and the pointer is already
/// telling you where it is, so the hover tint carries the whole affordance and
/// the ripple only adds a wave the platform never makes. It also runs 4× longer
/// than every other animation in a composer (120–160ms).
///
/// A getter, not a `final`: [AppSurface.hoverFill] resolves against the live
/// brightness at read time, so a top-level `final` would freeze whichever theme
/// happened to be up when this library was first touched.
ButtonStyle get composerNoSplash => ButtonStyle(
  splashFactory: NoSplash.splashFactory,
  overlayColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.hovered)
        ? AppSurface.hoverFill
        : Colors.transparent,
  ),
);

/// One quiet icon button in a composer's action row — attach a file, open the
/// saved prompts. A null [onPressed] disables it, and [tooltip] is expected to
/// say why in that state rather than going silent.
class ComposerIconButton extends StatelessWidget {
  const ComposerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppPalette.textSecondary — follow theme flips
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        iconSize: AppControl.iconSize,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
        style: composerNoSplash,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

/// Send — and, while an answer is coming, Stop.
///
/// It used to spin, disabled, with no way out: a reply that had gone the wrong
/// way had to be waited out. The button that started the turn is the one you
/// reach for to end it, so it becomes Stop for as long as the turn runs. That
/// the transcript already shows the work in flight is what frees this button to
/// be an action instead of a progress light.
///
/// With one exception, which is the whole point of the follow-up queue: once
/// there is something typed, this goes back to being Send — the message joins
/// the queue instead of going out now — and Stop moves to [ComposerStopButton]
/// beside it. Both actions stay reachable; neither is hidden behind clearing the
/// box.
///
/// [busyTooltip] is what the hover says while a turn runs and there is something
/// typed: the chat queues it behind the answer, and Code cannot ("Send when this
/// answer finishes" against a project that takes one task at a time), so each
/// says what pressing it will really do.
class ComposerSendButton extends StatelessWidget {
  const ComposerSendButton({
    super.key,
    required this.sending,
    required this.canSend,
    required this.onSend,
    required this.onStop,
    this.busyTooltip = 'Send when this answer finishes',
  });

  final bool sending;
  final bool canSend;
  final VoidCallback onSend;

  /// Ends the turn that is running. Null where nothing can be stopped — Code's
  /// box has no Stop of its own, since a task is stopped from the turn it
  /// belongs to.
  final VoidCallback? onStop;

  final String busyTooltip;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppTheme.pick/AppPalette tokens — follow theme flips
    final stops = sending && !canSend && onStop != null;
    return Tooltip(
      message: stops ? 'Stop' : (sending ? busyTooltip : 'Send'),
      child: SizedBox(
        width: 32,
        height: 32,
        child: FilledButton(
          onPressed: stops ? onStop : (canSend ? onSend : null),
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            splashFactory: NoSplash.splashFactory,
            // A high-contrast knob: dark-on-light in light mode, light-on-dark in
            // dark mode. Using textPrimary as the fill made a near-white circle
            // with a white icon in dark mode — the button vanished.
            backgroundColor: AppTheme.pick(
              AppPalette.textPrimary,
              const Color(0xFFF5F5F5),
            ),
            foregroundColor: AppTheme.pick(
              Colors.white,
              const Color(0xFF0A0A0A),
            ),
            // Disabled reads as *quiet*, not as a heavy grey knob: a soft fill
            // that sits a step off the composer's own surface, with a faint icon
            // — so "can't send yet" is legible without pulling the eye. The old
            // #9B9B9B was a dark solid grey that looked like an active button
            // dimmed. Warm-biased in light to match the app's paper tone.
            disabledBackgroundColor: AppTheme.pick(
              const Color(0xFFE7E7E4),
              const Color(0xFF2A2A2A),
            ),
            disabledForegroundColor: AppTheme.pick(
              const Color(0xFFB7B6AF),
              const Color(0xFF5C5C57),
            ),
          ),
          child: Icon(
            stops ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: AppControl.iconSize,
            semanticLabel: stops ? 'Stop' : 'Send',
          ),
        ),
      ),
    );
  }
}

/// Stop, as its own control — shown only while a turn is running *and* the
/// composer holds a follow-up, since that is when [ComposerSendButton] is busy
/// being Send. Quieter than Send: ending a turn is the secondary action there.
class ComposerStopButton extends StatelessWidget {
  const ComposerStopButton({super.key, required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Tooltip(
      message: 'Stop',
      child: SizedBox(
        width: 32,
        height: 32,
        child: OutlinedButton(
          onPressed: onStop,
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            splashFactory: NoSplash.splashFactory,
            foregroundColor: AppPalette.textSecondary,
            side: BorderSide(color: AppPalette.divider),
          ),
          child: const Icon(
            Icons.stop_rounded,
            size: AppControl.iconSize,
            semanticLabel: 'Stop',
          ),
        ),
      ),
    );
  }
}
