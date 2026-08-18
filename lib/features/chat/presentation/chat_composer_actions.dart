part of 'chat_composer.dart';

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.busySendTooltip,
    required this.approvalPicker,
    this.agentPicker,
    required this.modelPicker,
    required this.onAttachFile,
    required this.onOpenCommands,
    required this.messageController,
    required this.onSend,
    required this.onStop,
  });

  final bool canAttach;
  final bool sending;
  final bool canSend;

  /// What Send promises while a turn is still running — see
  /// [ComposerSection.busySendTooltip].
  final String busySendTooltip;

  /// What the assistant may do to this computer — null when nothing on this turn
  /// can touch it (a picture goes to the grid, which has no filesystem), so the
  /// control isn't offered where it would mean nothing.
  final Widget? approvalPicker;

  /// Which agent answers text-only turns — sits just left of the model it runs.
  /// It stays visible on a pictured turn even though that request bypasses it.
  final Widget? agentPicker;
  final Widget modelPicker;
  final VoidCallback onAttachFile;
  final VoidCallback onOpenCommands;

  /// Where a transcribed voice clip lands — see [_MicButton].
  final TextEditingController messageController;
  final VoidCallback onSend;

  /// Cuts the reply off where it is. The same button as Send, because the thing
  /// you reach for to stop something is the thing that started it.
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      // Two groups pushed apart, rather than one flat row with a spacer in the
      // middle. The spacer version was the reason the composer had a hard floor
      // around 550px: every control was inflexible, so a narrower column
      // overflowed instead of tightening, and the chat pane had to refuse to go
      // below that. Grouped, each side is a [Flexible] that gives its pills room
      // to ellipsis — and the pane's floor becomes what this row can really do.
      //
      // Loose fit, so on a roomy composer both groups still take their natural
      // width and `spaceBetween` puts them exactly where they were.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // What goes into the turn.
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AttachButton(canAttach: canAttach, onAttach: onAttachFile),
                _CommandsButton(enabled: !sending, onPressed: onOpenCommands),
                if (approvalPicker != null) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 178),
                      child: approvalPicker!,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Who answers, and go.
          //
          // An even share, not the 2:1 this first had. Each group carries one
          // more control than the other side thinks: two icon buttons and a
          // pill here, two pills and a send button there. Giving the left a
          // third made *it* the first thing to break — the access pill was
          // squeezed to 33px against a floor of 58 and struck stripes across
          // the composer.
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Agent then model, the two halves of "who answers, and with
                // what" — bounded (not fixed) so the pill sizes to the agent's
                // name while its inner label can still ellipsis.
                if (agentPicker != null) ...[
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 132),
                      child: agentPicker!,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // The pills are chips, not push buttons, so both sit at
                // heightSmall. This used to force a bare 30 — a fifth number in
                // a row that already had 32/32/28/32, and it silently overrode
                // the AppControl.height the picker itself asks for.
                //
                // The fixed 140 stays: a model pill that resized to each name
                // would make the row twitch on every switch. Under a tighter
                // box a `SizedBox` gives way to the box, which is the whole
                // point of putting it in a [Flexible].
                Flexible(child: SizedBox(width: 140, child: modelPicker)),
                const SizedBox(width: 4),
                _MicButton(
                  sending: sending,
                  messageController: messageController,
                  onSend: onSend,
                ),
                const SizedBox(width: 4),
                // Stop only gets its own button when Send has been taken over
                // by a follow-up going out mid-answer; the rest of the time the
                // one round button is both.
                if (sending && canSend) ...[
                  ComposerStopButton(onStop: onStop),
                  const SizedBox(width: 6),
                ],
                ComposerSendButton(
                  sending: sending,
                  canSend: canSend,
                  busyTooltip: busySendTooltip,
                  onSend: onSend,
                  onStop: onStop,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Takes a picture or a document onto the message being typed.
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.canAttach, required this.onAttach});

  final bool canAttach;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) => ComposerIconButton(
    icon: Icons.add_rounded,
    // What it takes, in the words of the person attaching it: pictures and
    // office files, or a paste of either. Full says how much fits rather than
    // going quiet.
    tooltip: canAttach
        ? 'Attach a picture or a document'
        : 'Up to $maxChatImages pictures and $maxChatFiles files',
    onPressed: canAttach ? onAttach : null,
  );
}

/// Opens the saved-prompt menu, or saves the current draft as a prompt.
///
/// One button with two honest jobs: with the box empty it browses prompts (drops
/// a `/` in to open the menu); with a draft typed it offers to keep that draft
/// for reuse. The icon and tooltip switch so the user knows which before tapping.
/// Opens the `/` command menu, by typing the slash the menu watches for — the
/// same keystroke the user could have made, so there is one way in and not two.
class _CommandsButton extends StatelessWidget {
  const _CommandsButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ComposerIconButton(
    icon: Icons.bolt_outlined,
    tooltip: 'Commands',
    onPressed: enabled ? onPressed : null,
  );
}

/// Tap to record, tap again to stop, transcribe and send — sits right beside
/// [ComposerSendButton] so voice input reads as another way to fill the same
/// box, not a separate feature bolted on elsewhere.
class _MicButton extends ConsumerWidget {
  const _MicButton({
    required this.sending,
    required this.messageController,
    required this.onSend,
  });

  final bool sending;
  final TextEditingController messageController;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette.textSecondary — follow flips
    final phase = ref.watch(recordingControllerProvider);
    final recording = phase is RecordingActive;
    final busy = sending || phase is RecordingTranscribing;
    return Tooltip(
      message: switch (phase) {
        RecordingActive() => 'Stop recording',
        RecordingTranscribing() => 'Transcribing…',
        RecordingIdle() || RecordingFailed() => 'Voice input',
      },
      child: SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          iconSize: AppControl.iconSize,
          visualDensity: VisualDensity.compact,
          color: recording
              ? Theme.of(context).colorScheme.error
              : AppPalette.textSecondary,
          style: composerNoSplash,
          icon: switch (phase) {
            RecordingTranscribing() => const SizedBox(
              width: AppControl.iconSize,
              height: AppControl.iconSize,
              child: AppSpinner(size: SpinnerSize.small),
            ),
            RecordingActive() => const Icon(Icons.stop_rounded),
            RecordingIdle() ||
            RecordingFailed() => const Icon(Icons.mic_none_rounded),
          },
          onPressed: busy ? null : () => _tap(context, ref),
        ),
      ),
    );
  }

  Future<void> _tap(BuildContext context, WidgetRef ref) async {
    final transcript = await ref
        .read(recordingControllerProvider.notifier)
        .toggle();
    if (!context.mounted) return;
    final phase = ref.read(recordingControllerProvider);
    if (phase case RecordingFailed(:final message)) {
      ToastScope.show(
        context,
        ToastSpec(message: message, severity: ToastSeverity.error),
      );
      return;
    }
    final text = transcript?.trim();
    if (text == null || text.isEmpty) return;
    messageController.text = text;
    onSend();
  }
}
