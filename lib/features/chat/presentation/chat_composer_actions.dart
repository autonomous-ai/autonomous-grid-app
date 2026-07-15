part of 'chat_composer.dart';

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.approvalPicker,
    required this.modelPicker,
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
              SizedBox(width: 140, height: 30, child: modelPicker),
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
        iconSize: 19,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
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
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
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
            size: sending ? 18 : 17,
            semanticLabel: sending ? 'Stop' : 'Send',
          ),
        ),
      ),
    );
  }
}
