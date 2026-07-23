part of 'chat_composer.dart';

/// Kills the Material ink ripple on a button.
///
/// The app's ThemeData sets `splashFactory: InkRipple.splashFactory` app-wide —
/// a circle that expands from the click point over ~600ms. That is an Android
/// gesture idiom: on macOS a click lands instantly and the pointer is already
/// telling you where it is, so the hover tint carries the whole affordance and
/// the ripple only adds a wave the platform never makes. It also runs 4× longer
/// than every other animation in this composer (120–160ms).
/// A getter, not a `final`: [AppSurface.hoverFill] resolves against the live
/// brightness at read time, so a top-level `final` would freeze whichever theme
/// happened to be up when this library was first touched.
ButtonStyle get _noSplash => ButtonStyle(
  splashFactory: NoSplash.splashFactory,
  overlayColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.hovered)
        ? AppSurface.hoverFill
        : Colors.transparent,
  ),
);

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.approvalPicker,
    required this.modelPicker,
    required this.contextMeter,
    required this.onPickImage,
    required this.onOpenPrompts,
    required this.promptsSaveInput,
    required this.onSend,
    required this.onStop,
  });

  final bool canAttach;
  final bool sending;
  final bool canSend;

  /// What the assistant may do to this computer — null when nothing on this turn
  /// can touch it (a picture goes to the grid, which has no filesystem), so the
  /// control isn't offered where it would mean nothing.
  final Widget? approvalPicker;
  final Widget modelPicker;

  /// The context ring, or null where a transcript keeps no history to fill.
  final Widget? contextMeter;
  final VoidCallback onPickImage;
  final VoidCallback onOpenPrompts;
  final bool promptsSaveInput;
  final VoidCallback onSend;

  /// Cuts the reply off where it is. The same button as Send, because the thing
  /// you reach for to stop something is the thing that started it.
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Row(
        children: [
          _AttachButton(canAttach: canAttach, onPickImage: onPickImage),
          _PromptsButton(
            enabled: !sending,
            savesInput: promptsSaveInput,
            onPressed: onOpenPrompts,
          ),
          const SizedBox(width: 4),
          if (approvalPicker != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 178),
              child: approvalPicker!,
            ),
          const Expanded(child: SizedBox()),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The two pills are chips, not push buttons, so both sit at
              // heightSmall. This used to force a bare 30 — a fifth number in a
              // row that already had 32/32/28/32, and it silently overrode the
              // AppControl.height the picker itself asks for.
              //
              // The ring sits between the model and Send: it measures that
              // model's memory, and the two read as one answer to "what am I
              // talking to, and how much room is left in it?" — right where the
              // eye already is on its way to the button. It costs no width at
              // all until there's a real reading to show, so an empty chat
              // isn't given a gauge of nothing.
              SizedBox(width: 140, child: modelPicker),
              ?contextMeter,
              const SizedBox(width: 8),
              _SendButton(
                sending: sending,
                canSend: canSend,
                onSend: onSend,
                onStop: onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.canAttach, required this.onPickImage});

  final bool canAttach;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppPalette.textSecondary — follow theme flips
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: canAttach ? 'Attach image' : 'Up to $maxChatImages images',
        iconSize: AppControl.iconSize,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
        // No ripple: the app's ThemeData opts into InkRipple globally, which is
        // an Android idiom — a circle spreading from the click point. macOS
        // answers a click with an instant state change, so the hover tint is the
        // whole response.
        style: _noSplash,
        icon: const Icon(Icons.add_rounded),
        onPressed: canAttach ? onPickImage : null,
      ),
    );
  }
}

/// Opens the saved-prompt menu, or saves the current draft as a prompt.
///
/// One button with two honest jobs: with the box empty it browses prompts (drops
/// a `/` in to open the menu); with a draft typed it offers to keep that draft
/// for reuse. The icon and tooltip switch so the user knows which before tapping.
class _PromptsButton extends StatelessWidget {
  const _PromptsButton({
    required this.enabled,
    required this.savesInput,
    required this.onPressed,
  });

  final bool enabled;
  final bool savesInput;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppPalette.textSecondary — follow theme flips
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: savesInput ? 'Save as a prompt' : 'Insert a saved prompt',
        iconSize: AppControl.iconSize,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
        style: _noSplash,
        icon: Icon(
          savesInput
              ? Icons.bookmark_add_outlined
              : Icons.bookmark_outline_rounded,
        ),
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

/// Send — and, while an answer is coming, Stop.
///
/// It used to spin here, disabled, with no way out: a reply that had gone the
/// wrong way had to be waited out. The button that started the turn is the one
/// you reach for to end it, so it becomes Stop for as long as the turn runs.
/// That the transcript already shows the work in flight is what frees this
/// button to be an action instead of a progress light.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.sending,
    required this.canSend,
    required this.onSend,
    required this.onStop,
  });

  final bool sending;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppTheme.pick/AppPalette tokens — follow theme flips
    return Tooltip(
      message: sending ? 'Stop' : 'Send',
      child: SizedBox(
        width: 32,
        height: 32,
        child: FilledButton(
          onPressed: sending ? onStop : (canSend ? onSend : null),
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
            sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
            size: AppControl.iconSize,
            semanticLabel: sending ? 'Stop' : 'Send',
          ),
        ),
      ),
    );
  }
}
